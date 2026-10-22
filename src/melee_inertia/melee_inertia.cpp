#include "melee_inertia.h"
#include "vendor/heft/heft.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <new>

namespace {
using namespace heft;
struct Simulation {
    Body body;
    Grip grips[2];
    State state;
    World world;
    Controller previous[2];
    bool valid=false, support=false;
    unsigned int generation=0;
    double time=0, length=1, maxLag=.25, maxAngle=.7853981633974483;
    std::array<double,20> output{};
};
bool ReadPose(const double* input, Pose& pose) {
    if (!input) return false;
    for (int i=0;i<7;++i) if (!std::isfinite(input[i])) return false;
    for (int i=0;i<3;++i) if (std::abs(input[i])>1000) return false;
    double norm=0;
    for (int i=3;i<7;++i) norm+=input[i]*input[i];
    if (!std::isfinite(norm) || norm<.25 || norm>4) return false;
    pose={{input[0],input[1],input[2]},QNorm({input[3],input[4],input[5],input[6]})};
    return true;
}
void Emit(Simulation& s,const Controller& dominant,double recovery,int reset,double* output) {
    const auto pose=GripPose(s.state,s.body);
    const double values[20]={pose.pos.x,pose.pos.y,pose.pos.z,pose.rot.x,pose.rot.y,pose.rot.z,pose.rot.w,
        s.state.vel.x,s.state.vel.y,s.state.vel.z,s.state.angVel.x,s.state.angVel.y,s.state.angVel.z,
        s.body.weight,Len(Sub(pose.pos,dominant.pose.pos)),Len(RotVec(QMul(QConj(dominant.pose.rot),pose.rot))),
        recovery,s.support?1.0:0.0,static_cast<double>(reset),s.time};
    std::copy(values,values+20,s.output.begin());
    std::copy(s.output.begin(),s.output.end(),output);
}
void Constrain(Simulation& s,const Controller& target) {
    auto grip=GripPose(s.state,s.body);
    const auto error=Sub(grip.pos,target.pose.pos);
    const double distance=Len(error);
    if (distance>s.maxLag) {
        grip.pos=Add(target.pose.pos,Mul(error,s.maxLag/distance));
        const auto outward=Mul(error,1/distance);
        const auto relative=Sub(s.state.vel,target.vel);
        const double speed=Dot(relative,outward);
        if (speed>0) s.state.vel=Sub(s.state.vel,Mul(outward,speed));
    }
    const auto turn=RotVec(QMul(QConj(target.pose.rot),s.state.rot));
    const double angle=Len(turn);
    if (angle>s.maxAngle) {
        s.state.rot=QNorm(QMul(target.pose.rot,QFromAxisAngle(Mul(turn,1/angle),s.maxAngle)));
        s.state.angVel=target.angVel;
    }
    s.state.com=Add(grip.pos,Rotate(s.state.rot,s.body.com));
}
void Muscles(Simulation& s,double recovery) {
    const double ease=recovery*recovery*(3-2*recovery);
    const double authority=.3+.7*ease;
    const double moment=(s.body.inertia.m[0][0]+s.body.inertia.m[1][1]+s.body.inertia.m[2][2])/3;
    for(int i=0;i<2;++i) {
        auto& m=s.grips[i].muscle;
        const double leverage=i==1?1.5:1.0;
        m.spring=2000*authority*leverage;
        m.damper=1.8*std::sqrt(m.spring*s.body.mass);
        m.maxForce=250*authority*leverage;
        m.torqueSpring=200*authority*leverage;
        m.torqueDamper=3.4*std::sqrt(m.torqueSpring*moment);
        m.maxTorque=40*authority*leverage;
        m.torqueSoft=.13962634015954636;
    }
}
}

int dtvr_melee_abi(){return 4;}
void* dtvr_melee_create(int profile) {
    if(profile<0 || profile>3) return nullptr;
    constexpr double mass[4]={.2,.5,.8,1.4};
    constexpr double length[4]={.30,.95,.80,1.25};
    constexpr double head[4]={.1,.1,.45,.65};
    return dtvr_melee_create_config(profile,mass[profile],length[profile],head[profile]);
}
void* dtvr_melee_create_config(int profile,double m,double l,double h) {
    if(profile<0 || profile>3 || !std::isfinite(m) || !std::isfinite(l) || !std::isfinite(h) ||
        m<.05 || m>10 || l<.1 || l>2.5 || h<.01 || h>.95) return nullptr;
    auto* s=new(std::nothrow) Simulation;
    if(!s) return nullptr;
    s->length=l;
    const Piece pieces[2]={{{0,0,-.08},{0,0,l},.025,m*(1-h)},
        {{-.06,0,l*.85},{.06,0,l*.85},.05,m*h}};
    // Weapon mass/inertia remain identical when the support grip engages.
    s->body=Build(pieces,2,nullptr,0,0);
    s->world.gravity={0,0,-9.81}; s->world.substep=1.0/360;
    s->world.snapDistance=100; s->world.iterations=8;
    s->maxLag=profile==0?.15:.25;
    s->maxAngle=profile==0?.5235987755982988:.7853981633974483;
    s->grips[0].rot={}; s->grips[0].on=true; s->grips[1].on=false;
    return s;
}
void dtvr_melee_destroy(void* state){delete static_cast<Simulation*>(state);}
int dtvr_melee_step(void* handle,const double* dominant7,const double* support7,
    double time,double recovery,int supportHeld,int trackingValid,unsigned int generation,double* output) {
    auto* s=static_cast<Simulation*>(handle);
    if(!s || !output) return 0;
    Controller now[2]{};
    if(!trackingValid || !std::isfinite(time) || !std::isfinite(recovery) ||
        !ReadPose(dominant7,now[0].pose)) {
        s->valid=false; s->support=false;
        std::fill(output,output+20,0.0);
        return 0;
    }
    recovery=std::clamp(recovery,0.0,1.0);
    if(!ReadPose(support7,now[1].pose)) {
        if(supportHeld) {s->valid=false;std::fill(output,output+20,0.0);return 0;}
        now[1].pose=now[0].pose;
    }
    int reset=0;
    if(!s->valid) reset=1;
    else if(s->generation!=generation) reset=2;
    else if(time<s->time || time-s->time>.1) reset=3;
    else if(Len(Sub(now[0].pose.pos,s->previous[0].pose.pos))>1 ||
        Len(RotVec(QMul(now[0].pose.rot,QConj(s->previous[0].pose.rot))))>2.2 ||
        (s->support && supportHeld && (Len(Sub(now[1].pose.pos,s->previous[1].pose.pos))>1 ||
        Len(RotVec(QMul(now[1].pose.rot,QConj(s->previous[1].pose.rot))))>2.2))) reset=4;
    else if(time==s->time) {std::copy(s->output.begin(),s->output.end(),output); return 3;}
    if(reset) {
        Place(s->state,s->body,s->grips[0],now[0].pose);
        s->valid=true; s->support=false; s->generation=generation; s->time=time;
        s->previous[0]=now[0]; s->previous[1]=now[1];
        Emit(*s,now[0],recovery,reset,output);
        return 2;
    }
    const double dt=time-s->time;
    for(int i=0;i<2;++i) {
        now[i].vel=Mul(Sub(now[i].pose.pos,s->previous[i].pose.pos),1/dt);
        now[i].angVel=Mul(RotVec(QMul(now[i].pose.rot,QConj(s->previous[i].pose.rot))),1/dt);
    }
    if(!supportHeld) s->support=false;
    else if(!s->support) {
        const auto grip=GripPose(s->state,s->body);
        const auto local=Rotate(QConj(grip.rot),Sub(now[1].pose.pos,grip.pos));
        if(local.z>=-.08 && local.z<=s->length && std::sqrt(local.x*local.x+local.y*local.y)<=.15) {
            s->support=true; s->grips[1].at={0,0,local.z};
            s->grips[1].rot=QNorm(QMul(QConj(grip.rot),now[1].pose.rot));
        }
    }
    s->grips[1].on=s->support;
    Muscles(*s,recovery);
    Step(s->state,s->body,s->grips,s->previous,now,2,dt,s->world);
    Constrain(*s,now[0]);
    s->time=time; s->previous[0]=now[0]; s->previous[1]=now[1];
    Emit(*s,now[0],recovery,0,output);
    for(double value:s->output) if(!std::isfinite(value)) {s->valid=false;std::fill(output,output+20,0.0);return 0;}
    return 1;
}
int dtvr_melee_contact(void* handle,double retention) {
    auto* s=static_cast<Simulation*>(handle);
    if(!s || !s->valid || !std::isfinite(retention) || retention<0 || retention>1) return 0;
    s->state.vel=Mul(s->state.vel,retention); s->state.angVel=Mul(s->state.angVel,retention);
    for(int i=7;i<=12;++i) s->output[i]*=retention;
    return 1;
}
int dtvr_melee_support_pose(void* handle,double* output) {
    auto* s=static_cast<Simulation*>(handle);
    if(!s || !output) return 0;
    if(!s->valid || !s->support) {std::fill(output,output+7,0.0);return 0;}
    const auto pose=HandPose(s->state,s->body,s->grips[1]);
    const double values[7]={pose.pos.x,pose.pos.y,pose.pos.z,pose.rot.x,pose.rot.y,pose.rot.z,pose.rot.w};
    std::copy(values,values+7,output);
    return 1;
}
int dtvr_melee_pin(void* handle,const double* input,double* output) {
    auto* s=static_cast<Simulation*>(handle);
    Pose pose;
    if(!s || !s->valid || !output || !ReadPose(input,pose)) return 0;
    // Reject rather than silently violating the real-controller separation cap.
    const auto& raw=s->previous[0];
    if(Len(Sub(pose.pos,raw.pose.pos))>s->maxLag+1e-8 ||
        Len(RotVec(QMul(QConj(raw.pose.rot),pose.rot)))>s->maxAngle+1e-8) return 0;
    Place(s->state,s->body,s->grips[0],pose);
    s->state.vel={};s->state.angVel={};
    Emit(*s,raw,s->output[16],0,output);
    return 1;
}

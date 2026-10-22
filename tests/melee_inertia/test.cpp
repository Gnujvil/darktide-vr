#include "../../src/melee_inertia/melee_inertia.h"
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>

using Pose=std::array<double,7>;
using Output=std::array<double,20>;
const Pose horizontal={0,0,1,-.7071067811865475,0,0,.7071067811865475};
struct Sim {
    void* ptr;
    explicit Sim(int profile):ptr(dtvr_melee_create(profile)){assert(ptr);}
    ~Sim(){dtvr_melee_destroy(ptr);}
    Sim(const Sim&)=delete;
    Sim& operator=(const Sim&)=delete;
    int step(const Pose& p,double time,Output& out,double recovery=1,bool held=false,
        const Pose* support=nullptr,bool valid=true,unsigned generation=1) {
        return dtvr_melee_step(ptr,p.data(),support?support->data():nullptr,time,recovery,held,valid,generation,out.data());
    }
};
Output settle(int profile,double recovery,bool two=false) {
    Sim sim(profile); Output out{}; Pose support=horizontal; support[1]=.3;
    assert(sim.step(horizontal,0,out,recovery,two,&support)==2);
    for(int i=1;i<=300;++i) assert(sim.step(horizontal,i/300.0,out,recovery,two,&support)==1);
    return out;
}
int main() {
    assert(dtvr_melee_abi()==4);
    assert(!dtvr_melee_create_config(3,0,1,.5));
    assert(!dtvr_melee_create_config(3,1,0,.5));
    assert(!dtvr_melee_create_config(3,1,1,1));
    assert(!dtvr_melee_create_config(3,std::numeric_limits<double>::quiet_NaN(),1,.5));
    auto* tuned=dtvr_melee_create_config(3,2.1,1.1,.55);
    assert(tuned);
    Output configured{};
    assert(dtvr_melee_step(tuned,horizontal.data(),nullptr,0,1,0,1,1,configured.data())==2);
    assert(std::abs(configured[13]-2.1)<1e-12);
    Pose constrained=horizontal;constrained[0]=.12;
    assert(dtvr_melee_pin(tuned,constrained.data(),configured.data())==1);
    assert(std::abs(configured[0]-.12)<1e-12 && configured[7]==0 && configured[19]==0);
    constrained[0]=.3;
    assert(dtvr_melee_pin(tuned,constrained.data(),configured.data())==0);
    assert(dtvr_melee_step(tuned,horizontal.data(),nullptr,0,1,0,1,1,configured.data())==3);
    assert(std::abs(configured[0]-.12)<1e-12);
    dtvr_melee_destroy(tuned);
    assert(!dtvr_melee_create(-1) && !dtvr_melee_create(4));
    Sim sim(3); Output out{};
    assert(sim.step(horizontal,0,out)==2 && out[14]<1e-12);
    Pose moved=horizontal; moved[0]=.10;
    assert(sim.step(moved,.01,out)==1);
    assert(out[14]>0 && out[14]<=.25 && std::abs(out[13]-1.4)<1e-12);
    const auto copy=out;
    assert(sim.step(moved,.01,out)==3 && out==copy);
    assert(dtvr_melee_contact(sim.ptr,0)==1);
    assert(sim.step(moved,.01,out)==3);
    for(int i=7;i<=12;++i) assert(out[i]==0);
    assert(sim.step(moved,.02,out,1,false,nullptr,false)==0);
    assert(sim.step(moved,.03,out)==2 && out[14]<1e-12);
    assert(sim.step(moved,.04,out,1,false,nullptr,true,2)==2 && out[18]==2);
    assert(sim.step(moved,.50,out,1,false,nullptr,true,2)==2 && out[18]==3);
    Pose jumped=moved; jumped[0]=2;
    assert(sim.step(jumped,.51,out,1,false,nullptr,true,2)==2 && out[18]==4 && out[14]<1e-12);
    Pose bad=moved; bad[3]=std::numeric_limits<double>::infinity();
    assert(sim.step(bad,.52,out)==0);
    const auto knife=settle(0,1);
    const auto hammer=settle(3,1);
    const auto tired=settle(3,0);
    const auto braced=settle(3,1,true);
    assert(hammer[14]>knife[14]);
    assert(tired[14]>hammer[14]);
    assert(std::abs(tired[13]-hammer[13])<1e-12 && std::abs(braced[13]-hammer[13])<1e-12);
    assert(braced[17]==1 && braced[14]<hammer[14]);
    Sim bounds(3);
    assert(bounds.step(horizontal,0,out)==2);
    for(int i=1;i<500;++i) {
        Pose target=horizontal; target[0]=2*std::sin(i*.37);
        assert(bounds.step(target,i*.01,out)==1);
        assert(out[14]<=.25000001 && out[15]<=.78539817);
        double norm=0;for(int j=3;j<7;++j) norm+=out[j]*out[j];
        assert(std::abs(norm-1)<1e-9);
        for(double value:out) assert(std::isfinite(value));
    }
    std::cout<<"melee_inertia=pass mass_profiles gravity recovery two_hand_leverage impact tracking_resets separation_caps\n"
        <<"lag knife="<<knife[14]<<" hammer="<<hammer[14]<<" tired="<<tired[14]<<" braced="<<braced[14]<<'\n';
}

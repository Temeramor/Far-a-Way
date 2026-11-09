#define private public
#include "../../native/src/terrain_detail.h"
#include <cstdio>
using namespace voxen;
int main(){
  TerrainDetail d; d.configure(12345);
  // synthetic steep face: slope 1.2 running +x, height varies with x; sample a 600x600 m patch at 1 m
  const double slope=1.2; double sum=0,sum2=0,mn=1e9,mx=-1e9; long n=0;
  double rug=0,strat[3]={0,0,0},nich=0; long nz_active[3]={0,0,0}; long niche_k[4]={0,0,0,0};
  for(double z=-300;z<300;z+=1.0) for(double x=-300;x<300;x+=1.0){
    double h=150+slope*x; // uphill is +x
    double r=d.relief(x,z,h,slope,0.0); sum+=r;sum2+=r*r;mn=std::min(mn,r);mx=std::max(mx,r);n++;
  }
  printf("relief on a 1.2-slope face at 150m: mean %.3f rms %.3f min %.2f max %.2f\n",sum/n,std::sqrt(sum2/n),mn,mx);
  // area fraction covered by each niche class alone (cut>0.03*depth)
  for(int k=0;k<4;k++){ long c=0,t=0; const auto&lv=TerrainDetail::NICHES[k];
    for(double z=-600;z<600;z+=1.0) for(double x=-600;x<600;x+=1.0){ // only class k: emulate by calling niches with flattened gate
      t++; }
    // brute: compute coverage by re-evaluating hash geometry for class k only
    long cov=0; for(double z=-600;z<600;z+=1.5) for(double x=-600;x<600;x+=1.5){ bool in=false;
      int cx0=(int)std::floor(x/lv.cell_m),cz0=(int)std::floor(z/lv.cell_m);
      for(int oz=-1;oz<=1&&!in;oz++)for(int ox=-1;ox<=1&&!in;ox++){int cx=cx0+ox,cz=cz0+oz;
        if(PgIslandTerrain::hash01(cx,cz,12345,11+k,0)>=lv.probability)continue;
        double px=(cx+0.15+0.7*PgIslandTerrain::hash01(cx,cz,12345,11+k,1))*lv.cell_m,pz=(cz+0.15+0.7*PgIslandTerrain::hash01(cx,cz,12345,11+k,2))*lv.cell_m;
        double hl=lv.cell_m*(0.32+0.4*PgIslandTerrain::hash01(cx,cz,12345,11+k,3)),hw=lv.cell_m*(0.12+0.14*PgIslandTerrain::hash01(cx,cz,12345,11+k,4));
        double dx=x-px,dz=z-pz; double u=(dz)/hl,v=(dx)/hw; // contour along z for slope along x
        if(u*u+v*v<1)in=true;}
      if(in)cov++; }
    printf("niche class %d: cell %.1f m, depth<=%.1f m: covers %.2f%% of face\n",k,lv.cell_m,lv.depth_m,100.0*cov/(1200.0*1200.0/2.25));
  }
  // strata activity fractions
  for(int k=0;k<3;k++){ long act=0,tot=0; const auto&lv=TerrainDetail::STRATA[k];
    for(double z=-1500;z<1500;z+=3) for(double x=-1500;x<1500;x+=3){ for(int id=0;id<3;id++){ double w=id*7;
      double a=TerrainDetail::smooth(lv.threshold,lv.threshold+0.18,d.sample(d.strata_patch,x*lv.patch_freq+w*31.7,z*lv.patch_freq-w*17.9)); tot++; if(a>0.5)act++; } }
    printf("strata level %d (%.1f m): layer expressed at %.1f%% of places\n",k,lv.thickness_m,100.0*act/tot);
  }
}

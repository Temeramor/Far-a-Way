#include <cstdio>
#include <cmath>
#include <chrono>
#include <vector>
#include <algorithm>
void* make_set(long,double); double hs(void*,double,double); double hc(void*,double,double);
int main(){
  void* n=make_set(12345,8000.0);
  // A: waterline vs analytic coast
  const int NB=13; int cnt[NB]={0},pos[NB]={0};
  for(double z=-3500;z<3500;z+=3.1) for(double x=-3500;x<3500;x+=3.1){
    double s=hc(n,x,z); if(s<-60||s>60) continue; int b=(int)((s+60)/10); if(b>=NB)b=NB-1;
    cnt[b]++; if(hs(n,x,z)>0) pos[b]++; }
  printf("fraction of terrain above water by analytic coast SDF bin:\n");
  for(int b=0;b<NB;b++) printf("  sdf[%4d,%4d) frac(h>0)=%.2f\n",-60+b*10,-50+b*10,cnt[b]?(double)pos[b]/cnt[b]:0.0);
  // misclassification band: distance of h=0 crossing from sdf=0 along the coast gradient
  // C: timing
  auto t0=std::chrono::steady_clock::now(); double acc=0; long calls=0;
  for(double z=-3000;z<3000;z+=6.1) for(double x=-3000;x<3000;x+=6.1){ acc+=hs(n,x,z); calls++; }
  auto t1=std::chrono::steady_clock::now();
  printf("timing: %ld calls, %.1f ns/call (acc %.1f)\n",calls,std::chrono::duration<double,std::nano>(t1-t0).count()/calls,acc);
}

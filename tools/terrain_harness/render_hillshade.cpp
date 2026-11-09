#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>
void* make_set(long,double); double hs(void*,double,double); double hc(void*,double,double); double hr(void*,double,double);
int main(int argc,char**argv){
  void* n=make_set(12345,8000.0);
  if(argc>1 && !strcmp(argv[1],"find")){
    // rocky shore candidates and steep high mountain faces
    int shown=0;
    for(double a=0;a<360&&shown<8;a+=3){ double ang=a*M_PI/180,dx=cos(ang),dz=sin(ang);
      for(double r=200;r<3900;r+=4){ double c=hc(n,dx*r,dz*r); if(c<0){ double x=dx*r,z=dz*r; double rk=hr(n,x,z);
          if(rk>0.9){ printf("rocky shore a=%.0f at (%.0f,%.0f) rocky=%.2f inland h(+30m)=%.1f\n",a,x,z,rk,hs(n,x-dx*30,z-dz*30)); shown++; } break; } } }
    // mountain: highest point on coarse grid
    double best=-1e9,bx=0,bz=0; for(double z=-3000;z<3000;z+=20) for(double x=-3000;x<3000;x+=20){ double h=hs(n,x,z); if(h>best){best=h;bx=x;bz=z;} }
    printf("highest point (%.0f,%.0f) h=%.1f\n",bx,bz,best); return 0; }
  double cx=atof(argv[1]),cz=atof(argv[2]),size=atof(argv[3]); int res=atoi(argv[4]); const char*out=argv[5]; int mode=argc>6?atoi(argv[6]):0;
  double step=size/res; std::vector<float> H((size_t)res*res);
  for(int j=0;j<res;j++) for(int i=0;i<res;i++) H[(size_t)j*res+i]=(float)hs(n,cx-size/2+i*step,cz-size/2+j*step);
  FILE*f=fopen(out,"wb"); fprintf(f,"P6\n%d %d\n255\n",res,res);
  double lx=-0.55,ly=0.62,lz=-0.55; double ll=sqrt(lx*lx+ly*ly+lz*lz); lx/=ll;ly/=ll;lz/=ll;
  for(int j=0;j<res;j++) for(int i=0;i<res;i++){
    auto at=[&](int a,int b){a=std::clamp(a,0,res-1);b=std::clamp(b,0,res-1);return (double)H[(size_t)b*res+a];};
    double gx=(at(i+1,j)-at(i-1,j))/(2*step), gz=(at(i,j+1)-at(i,j-1))/(2*step);
    double nx=-gx,ny=1,nz=-gz; double nl=sqrt(nx*nx+ny*ny+nz*nz); nx/=nl;ny/=nl;nz/=nl;
    double sh=std::max(0.0,nx*lx+ny*ly+nz*lz); sh=0.25+0.85*sh; double h=at(i,j); double sl=sqrt(gx*gx+gz*gz);
    double r,g,b; if(h<0){ double d=std::clamp(-h/25.0,0.0,1.0); r=40*(1-d)+10*d; g=120*(1-d)+50*d; b=170*(1-d)+110*d; sh=0.75+0.25*sh; }
    else if(sl>1.0){ r=g=b=125; } else if(sl>0.6){ double t=(sl-0.6)/0.4; r=90*(1-t)+125*t; g=130*(1-t)+125*t; b=70*(1-t)+125*t; } else if(h<3){ r=215;g=185;b=120; } else { r=80;g=140;b=65; }
    fputc((int)std::clamp(r*sh,0.0,255.0),f);fputc((int)std::clamp(g*sh,0.0,255.0),f);fputc((int)std::clamp(b*sh,0.0,255.0),f); }
  fclose(f); }

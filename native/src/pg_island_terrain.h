#pragma once

// Deterministic, world-global PG-Island inspired macro terrain and erosion.
// The field is generated once per seed and shared by every chunk sampler.
// It deliberately keeps simulation resolution independent from voxel resolution.

#include "../thirdparty/FastNoiseLite.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <numeric>
#include <initializer_list>
#include <vector>

namespace voxen {

class PgIslandTerrain {
public:
    static constexpr int RES = 2048;
    static constexpr int HYDRO_RES = 512;
    // Stripe-direction guide for slope_aligned_gullies: height blur radius as a fraction of the
    // octave's cell size. The raw per-cell gradient flips direction from cell to cell and, since
    // the stripe phase is (distance * direction), that becomes cell-sized noise (the "spikes").
    static constexpr double GULLY_GUIDE_BLUR = 0.30;
    // Angle of repose for thermal_relaxation, as slope (rise/run). 0.34 flattened every hill into
    // axis-aligned facets at the finer 2048 grid; 0.8 only touches genuinely steep rock faces.
    static constexpr double THERMAL_TALUS_SLOPE = 0.80;

    int64_t seed = 0;
    double world_size = 8000.0;
    std::vector<float> coast;
    std::vector<float> height;
    std::vector<float> drainage;
    fastnoiselite::FastNoiseLite warp_x, warp_z, coast_large, coast_small, coast_detail;
    double coast_ca=1.0, coast_sa=0.0, coast_aspect=1.0, coast_radius_scale=1.0;
    double coast_radius=std::sqrt(4000000.0/3.141592653589793), coast_threshold=0.0;
    fastnoiselite::FastNoiseLite broad, hills, detail, mountain, structure, fine, mountain_warp_x, mountain_warp_z;

    struct Massif { double x,z,angle,long_r,short_r,peak,freq,phase,warp; };
    std::vector<Massif> massifs;

    static double smooth(double a,double b,double v) {
        double t=std::clamp((v-a)/(b-a),0.0,1.0); return t*t*(3.0-2.0*t);
    }
    static uint32_t hash(uint32_t x,uint32_t y,uint32_t s,uint32_t octave,uint32_t lane) {
        uint32_t v=x*374761393u+y*668265263u+(s%65521u)*69069u+octave*362437u+lane*1013904223u;
        v=(v^(v>>13))*1274126177u; return v^(v>>16);
    }
    static double hash01(int x,int y,int64_t s,int octave,int lane) {
        return static_cast<double>(hash(static_cast<uint32_t>(x),static_cast<uint32_t>(y),
            static_cast<uint32_t>(s),static_cast<uint32_t>(octave),static_cast<uint32_t>(lane)) & 0x7fffffffu)/2147483647.0;
    }
    static fastnoiselite::FastNoiseLite noise(int32_t s,float frequency,int octaves=4) {
        fastnoiselite::FastNoiseLite n; n.SetSeed(s);
        n.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
        n.SetFrequency(frequency); n.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_FBm);
        n.SetFractalOctaves(octaves); n.SetFractalLacunarity(2.0f); n.SetFractalGain(0.5f); return n;
    }
    static float sample(const fastnoiselite::FastNoiseLite &n,double x,double z) {
        return n.GetNoise(static_cast<float>(x),static_cast<float>(z));
    }

    void generate(int64_t p_seed,double p_world_size) {
        seed=p_seed; world_size=p_world_size;
        massifs.clear();
        const int count=RES*RES;
        warp_x=noise(static_cast<int32_t>(seed+101),0.00115f,3);
        warp_z=noise(static_cast<int32_t>(seed+211),0.00115f,3);
        coast_large=noise(static_cast<int32_t>(seed+307),0.0038f,4);
        coast_small=noise(static_cast<int32_t>(seed+401),0.0125f,2);
        coast_detail=noise(static_cast<int32_t>(seed+419),0.027f,2);
        broad=noise(static_cast<int32_t>(seed+503),0.00135f,5);
        hills=noise(static_cast<int32_t>(seed+607),0.0052f,4);
        detail=noise(static_cast<int32_t>(seed+709),0.023f,3);
        mountain=noise(static_cast<int32_t>(seed+811),1.0f,5);
        structure=noise(static_cast<int32_t>(seed+829),0.0065f,4);
        fine=noise(static_cast<int32_t>(seed+839),0.014f,3);
        mountain_warp_x=noise(static_cast<int32_t>(seed+823),0.0017f,4);
        mountain_warp_z=noise(static_cast<int32_t>(seed+827),0.0017f,4);

        coast.resize(count); height.resize(count); drainage.assign(count,0.0f);
        uint64_t state=static_cast<uint64_t>(seed)^0x9e3779b97f4a7c15ULL;
        auto random01=[&]() { state^=state>>12; state^=state<<25; state^=state>>27;
            return static_cast<double>((state*2685821657736338717ULL)>>11)*(1.0/9007199254740992.0); };
        const double rotation=random01()*6.283185307179586;
        coast_aspect=0.76+random01()*0.52;
        coast_radius_scale=0.93+random01()*0.15;
        coast_ca=std::cos(rotation); coast_sa=std::sin(rotation);
        for(int y=0;y<RES;++y) {
            const double z=(static_cast<double>(y)/(RES-1)-0.5)*world_size;
            for(int x=0;x<RES;++x) {
                const double wx=(static_cast<double>(x)/(RES-1)-0.5)*world_size;
                coast[x+y*RES]=evaluate_coast(wx,z);
            }
        }
        // Calibrate to the same approximate 4 km² sampled land area as PG-Island.
        // Coastline calibration uses the complete field, including the added fine coastal octave.
        std::vector<float> sorted=coast;
        const double pixel_area=world_size*world_size/((RES-1.0)*(RES-1.0));
        const size_t target=std::clamp(static_cast<size_t>(std::llround(4000000.0/pixel_area)),size_t(1),sorted.size()-1);
        std::nth_element(sorted.begin(),sorted.begin()+static_cast<std::ptrdiff_t>(sorted.size()-target-1),sorted.end());
        coast_threshold=sorted[sorted.size()-target-1];
        for(float &v:coast) v-=static_cast<float>(coast_threshold);

        // Mountain systems are generated as one loose tectonic chain rather than
        // unrelated peaks scattered over the island. Their foothill aprons overlap,
        // while the individual cores keep separate summits and intervening valleys.
        const double count_roll=random01();
        const int massif_count=count_roll<0.16?1:(count_roll<0.57?2:(count_roll<0.86?3:(count_roll<0.97?4:5)));
        const double ridge_axis=random01()*6.283185307179586;
        const double axis_x=std::cos(ridge_axis),axis_z=std::sin(ridge_axis);
        const double side_x=-axis_z,side_z=axis_x;
        double anchor_x=0.0,anchor_z=0.0; bool anchor_found=false;
        for(int a=0;a<900&&!anchor_found;++a) {
            const double cx=(random01()*0.50-0.25)*world_size;
            const double cz=(random01()*0.50-0.25)*world_size;
            const int ix=std::clamp(static_cast<int>(std::llround((cx/world_size+0.5)*(RES-1))),0,RES-1);
            const int iz=std::clamp(static_cast<int>(std::llround((cz/world_size+0.5)*(RES-1))),0,RES-1);
            if(coast[ix+iz*RES]>420.0f){anchor_x=cx;anchor_z=cz;anchor_found=true;}
        }
        if(!anchor_found) {
            double best=-1e9;
            for(int i=0;i<count;i+=17) if(coast[i]>best) {
                best=coast[i];anchor_x=((i%RES)/(RES-1.0)-0.5)*world_size;
                anchor_z=((i/RES)/(RES-1.0)-0.5)*world_size;
            }
            anchor_found=best>0.0;
        }
        std::vector<std::pair<double,double>> centres;
        for(int m=0;m<massif_count&&anchor_found;++m) {
            double cx=anchor_x,cz=anchor_z; bool found=false;
            for(int a=0;a<900&&!found;++a) {
                const double spacing=610.0+random01()*230.0;
                const double along=(m-(massif_count-1)*0.5)*spacing;
                const double side=(random01()-0.5)*420.0;
                cx=anchor_x+axis_x*along+side_x*side;
                cz=anchor_z+axis_z*along+side_z*side;
                const int ix=std::clamp(static_cast<int>(std::llround((cx/world_size+0.5)*(RES-1))),0,RES-1);
                const int iz=std::clamp(static_cast<int>(std::llround((cz/world_size+0.5)*(RES-1))),0,RES-1);
                if(coast[ix+iz*RES]<300.0f) continue;
                found=true;
                for(const auto &p:centres) if(std::hypot(cx-p.first,cz-p.second)<430.0) found=false;
            }
            if(!found) {
                for(int a=0;a<700&&!found;++a) {
                    cx=anchor_x+(random01()*2.0-1.0)*1050.0;
                    cz=anchor_z+(random01()*2.0-1.0)*1050.0;
                    const int ix=std::clamp(static_cast<int>(std::llround((cx/world_size+0.5)*(RES-1))),0,RES-1);
                    const int iz=std::clamp(static_cast<int>(std::llround((cz/world_size+0.5)*(RES-1))),0,RES-1);
                    if(coast[ix+iz*RES]<300.0f) continue;
                    found=true;
                    for(const auto &p:centres) if(std::hypot(cx-p.first,cz-p.second)<430.0) found=false;
                }
            }
            if(!found) continue;
            centres.emplace_back(cx,cz);
            const double peak=200.0+400.0*std::pow(random01(),2.15), scale=1.0+0.28*(peak-200.0)/400.0;
            const double angle=ridge_axis+(random01()-0.5)*0.58;
            massifs.push_back({cx,cz,angle,(330.0+random01()*280.0)*scale,
                (215.0+random01()*180.0)*scale,peak,0.0032+random01()*0.002,
                random01()*2000.0-1000.0,70.0+random01()*75.0});
        }
        for(int y=0;y<RES;++y) {
            const double wz=(static_cast<double>(y)/(RES-1)-0.5)*world_size;
            for(int x=0;x<RES;++x) {
                const int i=x+y*RES; const double wx=(static_cast<double>(x)/(RES-1)-0.5)*world_size;
                const double sdf=coast[i]; double h=0.0;
                if(sdf>=0.0) {
                    const double inland=smooth(0,720,sdf);
                    h=2.8+12.0*smooth(0,155,sdf)+35.0*std::pow(inland,1.28);
                    h+=(sample(broad,wx,wz)*12.5+sample(hills,wx,wz)*5.5)*smooth(0,210,sdf)+sample(detail,wx,wz)*1.5;
                    double coastal=smooth(-180,500,sdf)*(1.0-smooth(620,1180,sdf));
                    h+=(std::max(static_cast<double>(sample(hills,wx*0.82,wz*0.82)),0.0)*28.0+
                        std::abs(sample(broad,wx*0.72,wz*0.72))*9.0)*coastal;
                    for(const auto &m:massifs) {
                        double lx=wx-m.x,lz=wz-m.z, c=std::cos(m.angle),s=std::sin(m.angle);
                        double tx=lx*c-lz*s,tz=lx*s+lz*c;
                        tx+=sample(mountain_warp_x,wx,wz)*m.warp; tz+=sample(mountain_warp_z,wx,wz)*m.warp;
                        double r=std::hypot(tx/m.long_r,tz/m.short_r);
                        r+=sample(mountain,tx*0.0024+m.phase,tz*0.0024-m.phase*0.37)*0.13;
                        const double core=1.0-smooth(0.10,1.14,r), apron=1.0-smooth(0.62,2.38,r);
                        if(core>0.0005||apron>0.0005) {
                            const double ridge=std::pow(1.0-std::abs(sample(mountain,tx*m.freq+m.phase,tz*m.freq-m.phase*0.37)),1.8);
                            const double broad_var=sample(structure,tx*0.006+m.phase*0.13,tz*0.006-m.phase*0.09);
                            const double secondary=std::pow(1.0-std::abs(sample(fine,tx*m.freq*0.42+m.phase*0.71,tz*m.freq*0.42-m.phase*0.29)),2.15);
                            const double valley=std::pow(std::max(1.0-std::abs(broad_var)*2.7,0.0),2.0);
                            const double spire=std::pow(std::max(1.0-r/0.48,0.0),1.85);
                            double core_h=m.peak*std::pow(std::max(core,0.0),1.22)*(0.43+0.22*ridge+0.13*secondary);
                            core_h+=m.peak*0.34*spire; core_h-=m.peak*0.045*valley*core;
                            core_h=std::min(std::max(core_h,m.peak*spire),m.peak)*smooth(-80,320,sdf);
                            double foothill=76.0*std::pow(std::max(apron,0.0),1.58)*(0.70+0.20*ridge+0.10*broad_var)*smooth(-180,430,sdf);
                            h+=std::max(core_h,0.0)+foothill;
                        }
                    }
                    h=std::max(h,0.35);
                } else {
                    const double offshore=std::min(-sdf,2600.0);
                    h=-(17.0*smooth(0,180,offshore)+505.0*smooth(130,2150,offshore)+
                        sample(broad,wx*0.75,wz*0.75)*18.0+sample(hills,wx,wz)*5.0);
                }
                height[i]=static_cast<float>(h);
            }
        }
        shallow_water_erosion();
        droplet_erosion();
        slope_aligned_gullies();
        thermal_relaxation();
    }

    float sample_height(double x,double z) const { return sample_field(height,x,z); }
    // Evaluate the same calibrated coastline field at arbitrary world coordinates.
    // This removes the 3.9 m raster/interpolation quantization from shoreline queries
    // while keeping the erosion simulation on its deterministic 2048² source grid.
    float sample_coast(double x,double z) const { return evaluate_coast(x,z); }
    float sample_drainage(double x,double z) const { return sample_field(drainage,x,z); }

private:
    float evaluate_coast(double wx,double wz) const {
        const double px=wx+sample(warp_x,wx,wz)*185.0;
        const double pz=wz+sample(warp_z,wx,wz)*185.0;
        const double rx=px*coast_ca-pz*coast_sa;
        const double rz=px*coast_sa+pz*coast_ca;
        const double coast_noise=sample(coast_large,wx,wz)*76.0+
            sample(coast_small,wx,wz)*23.0+sample(coast_detail,wx,wz)*7.5;
        return static_cast<float>(coast_radius*coast_radius_scale-
            std::hypot(rx/coast_aspect,rz*coast_aspect)+coast_noise-coast_threshold);
    }
    float sample_field(const std::vector<float>& field,double x,double z) const {
        if(field.empty()) return 0.0f;
        const double gx=(x/world_size+0.5)*(RES-1), gz=(z/world_size+0.5)*(RES-1);
        const int ix=std::clamp(static_cast<int>(std::floor(gx)),0,RES-1), iz=std::clamp(static_cast<int>(std::floor(gz)),0,RES-1);
        const double tx=std::clamp(gx-ix,0.0,1.0), tz=std::clamp(gz-iz,0.0,1.0);
        auto at=[&](int a,int b){return field[std::clamp(a,0,RES-1)+std::clamp(b,0,RES-1)*RES];};
        // Catmull-Rom bicubic interpolation; clamp to the local 4x4 range to avoid overshoot.
        auto cubic=[](double p0,double p1,double p2,double p3,double t){return p1+0.5*t*(p2-p0+t*(2*p0-5*p1+4*p2-p3+t*(3*(p1-p2)+p3-p0)));};
        double rows[4]; float lo=1e30f,hi=-1e30f;
        for(int j=-1;j<=2;++j){double v[4];for(int k=-1;k<=2;++k){float q=at(ix+k,iz+j);v[k+1]=q;lo=std::min(lo,q);hi=std::max(hi,q);}rows[j+1]=cubic(v[0],v[1],v[2],v[3],tx);}
        return static_cast<float>(std::clamp(cubic(rows[0],rows[1],rows[2],rows[3],tz),static_cast<double>(lo),static_cast<double>(hi)));
    }
    void shallow_water_erosion() {
        const int n=HYDRO_RES*HYDRO_RES, stride=HYDRO_RES;
        std::vector<float> h(n), initial(n), coast_h(n), water(n,0), sediment(n,0), hard(n), rain(n);
        // Eight-way water transport avoids the four-direction bias that can
        // otherwise imprint the simulation grid into long slopes and valleys.
        std::array<std::vector<float>,8> flow;
        for(auto &f:flow) f.assign(n,0.0f);
        const std::array<int,8> dx={{-1,1,0,0,-1,1,-1,1}};
        const std::array<int,8> dy={{0,0,-1,1,-1,-1,1,1}};
        const std::array<int,8> opposite={{1,0,3,2,7,6,5,4}};
        const std::array<double,8> distance={{1.0,1.0,1.0,1.0,1.41421356237,1.41421356237,1.41421356237,1.41421356237}};
        std::vector<float> accum(n,0);
        std::vector<float> nw(n),ns(n),nh(n);
        for(int y=0;y<HYDRO_RES;++y)for(int x=0;x<HYDRO_RES;++x){
            int sx=static_cast<int>(std::llround(x*(RES-1.0)/(HYDRO_RES-1))),sy=static_cast<int>(std::llround(y*(RES-1.0)/(HYDRO_RES-1))),i=x+y*stride,si=sx+sy*RES;
            h[i]=initial[i]=height[si];coast_h[i]=coast[si];hard[i]=0.72f+static_cast<float>(hash01(x,y,seed,0,3))*0.56f;rain[i]=0.78f+static_cast<float>(hash01(x,y,seed,0,4))*0.44f;
        }
        const double cell=world_size/(HYDRO_RES-1);
        constexpr int HYDRO_ITERATIONS=48;
        for(int iter=0;iter<HYDRO_ITERATIONS;++iter){
            for(int i=0;i<n;++i)if(coast_h[i]>0)water[i]+=0.26f*rain[i];
            for(auto &f:flow) std::fill(f.begin(),f.end(),0.0f);
            for(int y=1;y<HYDRO_RES-1;++y)for(int x=1;x<HYDRO_RES-1;++x){
                int i=x+y*stride;if(coast_h[i]<=0)continue;
                double surf=h[i]+water[i],raw[8]={},total=0.0;
                for(int k=0;k<8;++k){
                    int j=(x+dx[k])+(y+dy[k])*stride;
                    raw[k]=std::max(surf-h[j]-water[j],0.0)*0.14/distance[k];
                    total+=raw[k];
                }
                double scale=std::min(1.0,water[i]*0.78/std::max(total,0.00001));
                for(int k=0;k<8;++k) flow[k][i]=static_cast<float>(raw[k]*scale);
            }
            std::fill(nw.begin(),nw.end(),0.0f);
            std::fill(ns.begin(),ns.end(),0.0f);
            nh=h;
            for(int y=1;y<HYDRO_RES-1;++y)for(int x=1;x<HYDRO_RES-1;++x){
                int i=x+y*stride;if(coast_h[i]<=0)continue;
                double incoming=0.0,out=0.0,drop=0.0;
                for(int k=0;k<8;++k){
                    int j=(x+dx[k])+(y+dy[k])*stride;
                    incoming+=flow[opposite[k]][j];
                    out+=flow[k][i];
                    drop=std::max(drop,std::abs(static_cast<double>(h[i])-h[j]));
                }
                nw[i]=static_cast<float>(std::max(water[i]+incoming-out,0.0)*0.988);
                double capacity=(incoming+out)*(0.25+drop/cell*8.0),carried=sediment[i];
                if(incoming+out>0.008&&carried<capacity){double erode=std::min({(capacity-carried)*0.20*hard[i],0.42,std::max(h[i]-0.35,0.0)});nh[i]-=static_cast<float>(erode);carried+=erode;}
                else if(carried>capacity){double dep=std::min(carried,(carried-capacity)*0.24);nh[i]+=static_cast<float>(dep);carried-=dep;}
                double fraction=std::clamp(out/std::max(water[i]+incoming,0.02)*0.52,0.0,0.78),transport=carried*fraction;
                ns[i]+=static_cast<float>(carried-transport);
                if(out>1e-5){
                    for(int k=0;k<8;++k){int j=(x+dx[k])+(y+dy[k])*stride;
                        if(coast_h[j]>0) ns[j]+=static_cast<float>(transport*flow[k][i]/out);}
                }
                accum[i]+=static_cast<float>(incoming+out);
            }
            h.swap(nh);water.swap(nw);sediment.swap(ns);
            if(iter%8==7)thermal_coarse(h,coast_h,cell);
        }
        for(int y=0;y<RES;++y)for(int x=0;x<RES;++x){
            double gx=x*(HYDRO_RES-1.0)/(RES-1),gz=y*(HYDRO_RES-1.0)/(RES-1);
            int ix=std::min(static_cast<int>(gx),HYDRO_RES-2),iz=std::min(static_cast<int>(gz),HYDRO_RES-2);
            double tx=gx-ix,tz=gz-iz;auto val=[&](int a,int b){return h[a+b*stride]-initial[a+b*stride];};
            double a=val(ix,iz)*(1-tx)+val(ix+1,iz)*tx,b=val(ix,iz+1)*(1-tx)+val(ix+1,iz+1)*tx;
            int i=x+y*RES;if(coast[i]>0)height[i]=std::max(0.35f,height[i]+static_cast<float>((a*(1-tz)+b*tz)*0.92));
        }
        // Convert runoff to a normalized, sparse drainage guide. Raw accumulated
        // flux grows with iteration count and otherwise saturates downstream masks.
        std::vector<float> land_runoff; land_runoff.reserve(n);
        for(int i=0;i<n;++i) if(coast_h[i]>0.0f) land_runoff.push_back(accum[i]);
        float runoff_low=0.0f,runoff_high=1.0f;
        if(!land_runoff.empty()) {
            const size_t lo=std::min(land_runoff.size()-1,static_cast<size_t>(land_runoff.size()*0.84));
            const size_t hi=std::min(land_runoff.size()-1,static_cast<size_t>(land_runoff.size()*0.995));
            std::nth_element(land_runoff.begin(),land_runoff.begin()+static_cast<std::ptrdiff_t>(lo),land_runoff.end());
            runoff_low=land_runoff[lo];
            std::nth_element(land_runoff.begin(),land_runoff.begin()+static_cast<std::ptrdiff_t>(hi),land_runoff.end());
            runoff_high=std::max(land_runoff[hi],runoff_low+1e-4f);
        }
        for(int y=0;y<RES;++y)for(int x=0;x<RES;++x){
            double gx=x*(HYDRO_RES-1.0)/(RES-1),gz=y*(HYDRO_RES-1.0)/(RES-1);
            int ix=std::min(static_cast<int>(gx),HYDRO_RES-2),iz=std::min(static_cast<int>(gz),HYDRO_RES-2);
            double tx=gx-ix,tz=gz-iz;
            auto val=[&](int a,int b){return accum[a+b*stride];};
            double a=val(ix,iz)*(1-tx)+val(ix+1,iz)*tx,b=val(ix,iz+1)*(1-tx)+val(ix+1,iz+1)*tx;
            const double raw=a*(1-tz)+b*tz;
            drainage[x+y*RES]=coast[x+y*RES]>0.0f
                ? static_cast<float>(smooth(runoff_low,runoff_high,raw)) : 0.0f;
        }
    }
    void thermal_coarse(std::vector<float>& h,const std::vector<float>& c,double cell) {
        std::vector<float> delta(h.size(),0);const double talus=std::max(cell*0.075,2.8);
        const std::array<std::pair<int,double>,4> edges={{{1,1.0},{HYDRO_RES,1.0},{HYDRO_RES+1,1.41421356237},{HYDRO_RES-1,1.41421356237}}};
        for(int y=1;y<HYDRO_RES-1;++y)for(int x=1;x<HYDRO_RES-1;++x){int i=x+y*HYDRO_RES;if(c[i]<=0)continue;
            for(const auto &edge:edges){int j=i+edge.first;if(c[j]<=0)continue;double limit=talus*edge.second,diff=h[i]-h[j];
                if(std::abs(diff)>limit){double rate=edge.second>1.1?0.06:0.12;float t=static_cast<float>(std::min((std::abs(diff)-limit)*rate,0.75));delta[i]+=diff>0?-t:t;delta[j]+=diff>0?t:-t;}}
        }
        for(size_t i=0;i<h.size();++i)if(c[i]>0)h[i]=std::max(0.35f,h[i]+delta[i]);
    }
    float bilinear(const std::vector<float>& f,double x,double z) const {
        int x0=std::clamp(static_cast<int>(std::floor(x)),0,RES-1),z0=std::clamp(static_cast<int>(std::floor(z)),0,RES-1);
        int x1=std::min(x0+1,RES-1),z1=std::min(z0+1,RES-1);double tx=std::clamp(x-x0,0.0,1.0),tz=std::clamp(z-z0,0.0,1.0);
        double a=f[x0+z0*RES]*(1-tx)+f[x1+z0*RES]*tx,b=f[x0+z1*RES]*(1-tx)+f[x1+z1*RES]*tx;return static_cast<float>(a*(1-tz)+b*tz);
    }
    void deposit(double x,double z,double amount) {
        int x0=std::clamp(static_cast<int>(std::floor(x)),0,RES-2),z0=std::clamp(static_cast<int>(std::floor(z)),0,RES-2);
        double tx=std::clamp(x-x0,0.0,1.0),tz=std::clamp(z-z0,0.0,1.0);
        height[x0+z0*RES]+=static_cast<float>(amount*(1-tx)*(1-tz));height[x0+1+z0*RES]+=static_cast<float>(amount*tx*(1-tz));
        height[x0+(z0+1)*RES]+=static_cast<float>(amount*(1-tx)*tz);height[x0+1+(z0+1)*RES]+=static_cast<float>(amount*tx*tz);
    }
    double erode_brush(double x,double z,double amount) {
        int cx=static_cast<int>(std::floor(x)),cz=static_cast<int>(std::floor(z));double total=0;
        auto weight=[](int ox,int oz){return std::max(1.0-std::hypot(static_cast<double>(ox),static_cast<double>(oz))/1.65,0.0);};
        for(int oz=-1;oz<=1;++oz)for(int ox=-1;ox<=1;++ox){int sx=cx+ox,sz=cz+oz;if(sx<1||sz<1||sx>=RES-1||sz>=RES-1)continue;if(height[sx+sz*RES]>0.5f)total+=weight(ox,oz);}
        if(total<=1e-4)return 0;double removed=0;
        for(int oz=-1;oz<=1;++oz)for(int ox=-1;ox<=1;++ox){int sx=cx+ox,sz=cz+oz;if(sx<1||sz<1||sx>=RES-1||sz>=RES-1)continue;int i=sx+sz*RES;double take=std::min(std::max(static_cast<double>(height[i])-0.5,0.0),amount*weight(ox,oz)/total);height[i]-=static_cast<float>(take);removed+=take;}
        return removed;
    }
    void droplet_erosion() {
        uint64_t state=static_cast<uint64_t>(seed+17011)^0xda3e39cb94b95bdbULL;
        auto rnd=[&](){state^=state>>12;state^=state<<25;state^=state>>27;return static_cast<double>((state*2685821657736338717ULL)>>11)*(1.0/9007199254740992.0);};
        const double cell=world_size/(RES-1);
        for(int d=0;d<18000;++d){double x=0,z=0;bool spawned=false;
            for(int a=0;a<24;++a){double cx=1+rnd()*(RES-3),cz=1+rnd()*(RES-3);int ix=static_cast<int>(cx),iz=static_cast<int>(cz),i=ix+iz*RES;
                if(bilinear(coast,cx,cz)>95.0&&bilinear(height,cx,cz)>24.0){x=cx;z=cz;spawned=true;break;}}
            if(!spawned)continue;double dx=0,dz=0,speed=1,water_amount=1,sed=0;
            for(int life=0;life<52;++life){double before=bilinear(height,x,z);
                double gx=(bilinear(height,x+1,z)-bilinear(height,x-1,z))*0.5, gz=(bilinear(height,x,z+1)-bilinear(height,x,z-1))*0.5;
                dx=dx*0.12-gx*0.88;dz=dz*0.12-gz*0.88;double len=std::hypot(dx,dz);if(len<1e-6)break;dx/=len;dz/=len;
                double nx=x+dx,nz=z+dz;if(nx<1||nz<1||nx>=RES-2||nz>=RES-2||bilinear(coast,nx,nz)<=8.0)break;
                double after=bilinear(height,nx,nz),dh=after-before,capacity=std::max(-dh*speed*water_amount*4.0,0.035);
                if(sed>capacity||dh>0){double dep=dh>0?std::min(dh,sed):(sed-capacity)*0.34;dep=std::max(dep,0.0);deposit(x,z,dep);sed-=dep;}
                else {double erode=std::min((capacity-sed)*0.38,-dh);if(erode>0)sed+=erode_brush(x,z,erode);}
                speed=std::sqrt(std::max(speed*speed-dh*4.0,0.01));water_amount*=0.99;x=nx;z=nz;if(water_amount<0.05)break;
            }
        }
    }
    // Separable box blur (running sum) repeated `passes` times: close to a Gaussian.
    static void blur_field(std::vector<float>& f,int radius,int passes) {
        if(radius<1) return;
        std::vector<float> tmp(f.size());
        for(int p=0;p<passes;++p){
            for(int y=0;y<RES;++y){ const int row=y*RES; double sum=0;
                for(int k=-radius;k<=radius;++k) sum+=f[row+std::clamp(k,0,RES-1)];
                for(int x=0;x<RES;++x){ tmp[row+x]=static_cast<float>(sum/(2*radius+1));
                    sum+=f[row+std::min(x+radius+1,RES-1)]-f[row+std::max(x-radius,0)]; } }
            for(int x=0;x<RES;++x){ double sum=0;
                for(int k=-radius;k<=radius;++k) sum+=tmp[x+std::clamp(k,0,RES-1)*RES];
                for(int y=0;y<RES;++y){ f[x+y*RES]=static_cast<float>(sum/(2*radius+1));
                    sum+=tmp[x+std::min(y+radius+1,RES-1)*RES]-tmp[x+std::max(y-radius,0)*RES]; } }
        }
    }
    void slope_aligned_gullies() {
        const double world_step=world_size/(RES-1);
        for(int octave=0;octave<5;++octave) {
            const double cell_size=620.0/std::pow(2.0,octave);
            const std::vector<float> previous=height;
            std::vector<float> guide=previous;
            blur_field(guide,std::max(1,static_cast<int>(std::lround(cell_size*GULLY_GUIDE_BLUR/world_step))),3);
            std::vector<float> next=previous;
            const double stripe_frequency=6.283185307179586/(cell_size*0.34);
            const double amplitude=8.0/std::pow(2.0,octave);
            for(int y=1;y<RES-1;++y) {
                const double wz=(static_cast<double>(y)/(RES-1)-0.5)*world_size;
                for(int x=1;x<RES-1;++x) {
                    const int i=x+y*RES;
                    const double terrain=previous[i];
                    if(coast[i]<=0.0f) continue;
                    // Smooth onset instead of the old hard `terrain<38` cutoff, which left a
                    // cliff of several metres along the 38 m contour.
                    const double height_mask=smooth(30.0,64.0,terrain);
                    if(height_mask<=0.0) continue;
                    const double gx=(guide[i+1]-guide[i-1])/(2.0*world_step);
                    const double gz=(guide[i+RES]-guide[i-RES])/(2.0*world_step);
                    const double slope=std::hypot(gx,gz);
                    if(slope<0.012) continue;
                    // Gullies must follow the downhill gradient, not the contour tangent.
                    const double tx=-gx/std::max(slope,1e-4),tz=-gz/std::max(slope,1e-4);
                    const double wx=(static_cast<double>(x)/(RES-1)-0.5)*world_size;
                    const int cell_x=static_cast<int>(std::floor(wx/cell_size));
                    const int cell_y=static_cast<int>(std::floor(wz/cell_size));
                    double cs=0.0,sn=0.0,ws=0.0;
                    for(int oy=0;oy<2;++oy) for(int ox=0;ox<2;++ox) {
                        const int cx=cell_x+ox,cy=cell_y+oy;
                        const double jx=hash01(cx,cy,seed,octave,0),jy=hash01(cx,cy,seed,octave,1);
                        const double px=(cx+0.20+jx*0.60)*cell_size, pz=(cy+0.20+jy*0.60)*cell_size;
                        const double dx=wx-px,dz=wz-pz;
                        const double dw=1.0-std::clamp(std::hypot(dx,dz)/(cell_size*1.65),0.0,1.0);
                        const double weight=dw*dw;
                        if(weight>1e-4) {
                            const double phase=(dx*tx+dz*tz)*stripe_frequency+hash01(cx,cy,seed,octave,2)*6.283185307179586;
                            cs+=std::cos(phase)*weight;sn+=std::sin(phase)*weight;ws+=weight;
                        }
                    }
                    if(ws<=1e-4) continue;
                    double vx=cs/ws,vy=sn/ws,len=std::hypot(vx,vy);
                    if(len>1e-6){vx*=std::min(2.0*len,1.0)/len;} // continuous: the old `len>0.5` branch doubled the amplitude at a threshold
                    const double fade=2.0*smooth(45.0,270.0,terrain)-1.0;
                    const double slope_mask=1.0-std::pow(1.0-smooth(0.018,0.20,slope),2.0);
                    const double inland=smooth(25.0,190.0,coast[i]);
                    next[i]=static_cast<float>(std::max(0.35,terrain+(vx-fade)*amplitude*0.56*slope_mask*inland*height_mask));
                }
            }
            height.swap(next);
        }
    }

    void thermal_relaxation() {
        const double talus=world_size/(RES-1)*THERMAL_TALUS_SLOPE;
        // Process each undirected edge once. Diagonals use their true sqrt(2) run
        // and a lower transfer rate, removing the strong X/Z preference of the old
        // right/down-only relaxation without changing total transported material.
        const std::array<std::pair<int,double>,4> edges={{{1,1.0},{RES,1.0},{RES+1,1.41421356237},{RES-1,1.41421356237}}};
        for(int it=0;it<8;++it){std::vector<float> delta(height.size(),0);
            for(int y=1;y<RES-1;++y)for(int x=1;x<RES-1;++x){int i=x+y*RES;if(height[i]<=0||coast[i]<=0)continue;
                for(const auto &edge:edges){int j=i+edge.first;if(coast[j]<=0)continue;double limit=talus*edge.second,diff=height[i]-height[j];
                    if(std::abs(diff)>limit){double rate=edge.second>1.1?0.11:0.22;float t=static_cast<float>(std::min((std::abs(diff)-limit)*rate,1.5));delta[i]+=diff>0?-t:t;delta[j]+=diff>0?t:-t;}}
            }
            for(size_t i=0;i<height.size();++i)if(height[i]>0)height[i]=std::max(0.35f,height[i]+delta[i]);
        }
    }
};

} // namespace voxen

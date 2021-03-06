/*
 * Copyright 1993-2015 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

// Simple 3D volume renderer

#include <iostream>
#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <helper_cuda.h>
#include <helper_math.h>
#include "param.h"
using std::cout;
using std::endl;
#define M_PI 3.14159265358979323846

typedef unsigned int  uint;
typedef unsigned char uchar;
//typedef unsigned short VolumeType;
typedef unsigned char VolumeType;

class FractalJuliaSet
{
    float radius;
    float4 cc;
    int maxIter;

    __device__
    float4 quatSq(float4 q)
    {
        float3 q_yzw = make_float3(q.y, q.z, q.w);

        float r0 = q.x * q.x - dot(q_yzw, q_yzw);
        float3 r_yzw = q_yzw * (q.x * 2);

        return make_float4(
            r0,
            r_yzw.x,
            r_yzw.y,
            r_yzw.z);
    }

    __device__
    float eval_fractal(const float3& pos, float radius, const float4& c, int maxIter){

        float4 q = make_float4(pos.x * radius,
                               pos.y * radius,
                               pos.z * radius, 0);

        int iter = 0;
        do
        {
            q = quatSq(q);
            q += c;
        } while (dot(q, q) < 10.0f && iter++ < maxIter);

        //     return iter * (iter>5);
        //     return iter / float(maxIter);
        //     return log((float)iter+1) / log((float)maxIter);
        return (iter > maxIter * 0.9);
    }

public:
    __device__
    float density(const float3& pos)
    {
        return eval_fractal(pos, radius, cc, maxIter);
    }

    __device__
    FractalJuliaSet()
    {
        radius = 1.4f;//  3.0f;
        //     setFloat4(cc, -1, 0.2, 0, 0);
        //     setFloat4(cc, -0.291,-0.399,0.339,0.437);
        //     setFloat4(cc, -0.2,0.4,-0.4,-0.4);
        //     setFloat4(cc, -0.213,-0.0410,-0.563,-0.560);
        //     setFloat4(cc, -0.2,0.6,0.2,0.2);
        //     setFloat4(cc, -0.162,0.163,0.560,-0.599);
        cc = make_float4(-0.2f, 0.8f, 0.0f, 0.0f);
        //     setFloat4(cc, -0.445,0.339,-0.0889,-0.562);
        //     setFloat4(cc, 0.185,0.478,0.125,-0.392);
        //     setFloat4(cc, -0.450,-0.447,0.181,0.306);
        //     setFloat4(cc, -0.218,-0.113,-0.181,-0.496);
        //     setFloat4(cc, -0.137,-0.630,-0.475,-0.046);
        //     setFloat4(cc, -0.125,-0.256,0.847,0.0895);

        //     maxIter = 20;
        maxIter = 30;
    }
};

class CudaRng
{
    curandStateXORWOW_t state;

public:
    __device__
    void init(unsigned int seed)
    {
        curand_init(seed, 0, 0, &state);
    }

    __device__
    float next()
    {
        return curand_uniform(&state);
    }
};

cudaArray *d_volumeArray = 0;
texture<VolumeType, 3, cudaReadModeNormalizedFloat> density_tex;         // 3D texture
CudaRng *cuda_rng = nullptr;

class Frame
{
    float3 n, t, b; // normal, tangent, bitangent

public:
    __device__
    Frame(const float3& normal)
    {
        n = normalize(normal);
        float3 a = fabs(n.x) > 0.1 ? make_float3(0, 1, 0) : make_float3(1, 0, 0);
        t = normalize(cross(a, n));
        b = cross(n, t);
    }
    __device__
    float3 toWorld(const float3& c) const
    {
        return t * c.x + b * c.y + n * c.z;
    }
    __device__
    const float3& normal() const
    {
        return n;
    }
    __device__
    const float3& tangent() const
    {
        return t;
    }
    __device__
    const float3& bitangent() const
    {
        return b;
    }
};

class HGPhaseFunction
{
    float g;

    // perfect inversion, pdf matches evaluation exactly
    __device__
    float3 sample(float rnd0, float rnd1) const
    {
        float cos_theta;
        if (fabs(g) > 1e-6f)
        {
            float s = 2.0f * rnd0 - 1.0f;
            float f = (1.0f - g * g) / (1.0f + g * s);
            cos_theta = (0.5f / g) * (1.0f + g * g - f * f);
            cos_theta = max(0.0f, min(1.0f, cos_theta));
        }
        else
        {
            cos_theta = 2.0f * rnd0 - 1.0f;
        }
        float sin_theta = sqrt(1.0f - cos_theta * cos_theta);
        float phi = 2.0f * M_PI * rnd1;
        float3 ret = make_float3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
        return ret;
    }

    __device__
    float evaluate(float cos_theta) const
    {
        return (1.0f - g * g) / (4.0f * M_PI * pow(1.0f + g * g - 2 * g * cos_theta, 1.5f));
    }

public:
    __device__
    HGPhaseFunction(float g)
        : g(g)
    {

    }

    __device__
    float3 sample(const Frame& frame, float rnd0, float rnd1) const
    {
        float3 s = sample(rnd0, rnd1);
        return frame.toWorld(s);
    }

    __device__
    float evaluate(const Frame& frame, const float3& dir) const
    {
        float cos_theta = dot(frame.normal(), dir);
        return evaluate(cos_theta);
    }
}; 

typedef struct
{
    float4 m[3];
} float3x4;

__constant__ float3x4 c_invViewMatrix;  // inverse view matrix

struct Ray
{
    float3 o;   // origin
    float3 d;   // direction
};

// intersect ray with a box
// http://www.siggraph.org/education/materials/HyperGraph/raytrace/rtinter3.htm

__device__
int intersectBox(Ray r, float3 boxmin, float3 boxmax, float *tnear, float *tfar)
{
    // compute intersection of ray with all six bbox planes
    float3 invR = make_float3(1.0f) / r.d;
    float3 tbot = invR * (boxmin - r.o);
    float3 ttop = invR * (boxmax - r.o);

    // re-order intersections to find smallest and largest on each axis
    float3 tmin = fminf(ttop, tbot);
    float3 tmax = fmaxf(ttop, tbot);

    // find the largest tmin and the smallest tmax
    float largest_tmin = fmaxf(fmaxf(tmin.x, tmin.y), fmaxf(tmin.x, tmin.z));
    float smallest_tmax = fminf(fminf(tmax.x, tmax.y), fminf(tmax.x, tmax.z));

    *tnear = largest_tmin;
    *tfar = smallest_tmax;

    return smallest_tmax > largest_tmin;
}

// transform vector by matrix (no translation)
__device__
float3 mul(const float3x4 &M, const float3 &v)
{
    float3 r;
    r.x = dot(v, make_float3(M.m[0]));
    r.y = dot(v, make_float3(M.m[1]));
    r.z = dot(v, make_float3(M.m[2]));
    return r;
}

// transform vector by matrix with translation
__device__
float4 mul(const float3x4 &M, const float4 &v)
{
    float4 r;
    r.x = dot(v, M.m[0]);
    r.y = dot(v, M.m[1]);
    r.z = dot(v, M.m[2]);
    r.w = 1.0f;
    return r;
}

__device__
float vol_sigma_t(const float3& pos, float density)
{
//     return density;


//     // remap position to [0, 1] coordinates
//     float t = tex3D(density_tex, pos.x * 0.5f + 0.5f, pos.y * 0.5f + 0.5f, pos.z * 0.5f + 0.5f);
//     t = clamp(t, 0.0f, 1.0f) * density;
//     return t;


//     float x = pos.x * 0.5f + 0.5f;
//     float y = pos.y * 0.5f + 0.5f;
//     float z = pos.z * 0.5f + 0.5f;
//     int xi = (int)ceil(5.0 * x);
//     int yi = (int)ceil(5.0 * y);
//     int zi = (int)ceil(5.0 * z);
//     return float((xi + yi + zi) & 0x01) * density;


    FractalJuliaSet fract;
    return fract.density(pos) * density;
}

__device__
float Tr(
    const float3 boxMin,
    const float3 boxMax,
    const float3& start_point,
    const float3& end_point,
    float inv_sigma,
    float density,
    CudaRng& rng)
{
    Ray shadow_ray;
    shadow_ray.o = start_point;
    shadow_ray.d = normalize(end_point - start_point);

    float t_near, t_far;
    bool shade_vol = intersectBox(shadow_ray, boxMin, boxMax, &t_near, &t_far);
    if (!shade_vol)
    {
        return 1.0f;
    }
    if (t_near < 0.0f) t_near = 0.0f;     // clamp to near plane

    float max_t = min(t_far, length(start_point - end_point));

    float dist = t_near;

    for (;;)
    {
        dist += -log(rng.next()) * inv_sigma;
        if (dist >= max_t)
        {
            break;
        }
        float3 pos = shadow_ray.o + shadow_ray.d * dist;

        if (rng.next() < vol_sigma_t(pos, density) * inv_sigma)
        {
            break;
        }
    }
    return float(dist >= max_t);
}

__device__ __forceinline__
float4 background(const float3& dir)
{
    return make_float4(0.15f, 0.20f, 0.25f, 1.0f) * 0.5f * (dir.y + 0.5);
}

__global__ void
__d_render(float4 *d_output, CudaRng *rngs, const Param P)
{
    const float density = P.density;
    const float brightness = P.brightness;
    const float albedo = P.albedo;

    const float3 light_pos = make_float3(100, 100, 100);
    const float3 light_power = make_float3(1.0, 0.9, 0.8);

    const float3 boxMin = make_float3(-1.0f, -1.0f, -1.0f);
    const float3 boxMax = make_float3(1.0f, 1.0f, 1.0f);

    uint x = blockIdx.x*blockDim.x + threadIdx.x;
    uint y = blockIdx.y*blockDim.y + threadIdx.y;

    if ((x >= P.width) || (y >= P.height)) return;

    CudaRng& rng = rngs[x + y * P.width];
    float u = (x / (float) P.width) * 2.0f - 1.0f;
    float v = (y / (float) P.height) * 2.0f - 1.0f;

    HGPhaseFunction phase(P.g);

    // calculate eye ray in world space
    Ray cr;
    cr.o = make_float3(mul(c_invViewMatrix, make_float4(0.0f, 0.0f, 0.0f, 1.0f)));
    cr.d = normalize(make_float3(u, v, -2.0f));
    cr.d = mul(c_invViewMatrix, cr.d);

    float4 radiance = make_float4(0.0f);
    float throughput = 1.0f;

    int i;
    for (i = 0; i < 20000; i++)
    {
        // find intersection with box
        float t_near, t_far;
        int hit = intersectBox(cr, boxMin, boxMax, &t_near, &t_far);

        if (!hit)
        {
            radiance += background(cr.d) * throughput;
            break;
        }

        if (t_near < 0.0f)
        {
            t_near = 0.0f;     // clamp to near plane
        }

        /// woodcock tracking / delta tracking
        float3 pos = cr.o + cr.d * t_near; // current position
        float dist = t_near;
        float max_sigma_t = density;
        float inv_sigma = 1.0f / max_sigma_t;

        bool through = false;
        // delta tracking scattering event sampling
        for (;;)
        {
            dist += -log(rng.next()) * inv_sigma;
            pos = cr.o + cr.d * dist;
            if (dist >= t_far)
            {
                through = true; // transmitted through the volume, probability is 1-exp(-optical_thickness)
                break;
            }
            if (rng.next() < vol_sigma_t(pos, density) * inv_sigma)
            {
                break;
            }
        }

        // probability is exp(-optical_thickness)
        if (through)
        {
            radiance += background(cr.d) * throughput;
            break;
        }

        throughput *= albedo;

        Frame frame(cr.d);

        // direct lighting
        float a = Tr(boxMin, boxMax, pos, light_pos, inv_sigma, density, rng);
        radiance += make_float4(light_power * (throughput * phase.evaluate(frame, normalize(light_pos - pos)) * a), 0.0f);

        // scattered direction
        float3 new_dir = phase.sample(frame, rng.next(), rng.next());
        cr.o = pos;
        cr.d = new_dir;
    }

    radiance *= brightness;

    // write output color
    float heat = i * 0.001;
    d_output[x + y * P.width] += make_float4(
        max(radiance.x, 0.0f),
        max(radiance.y, 0.0f),
        max(radiance.z, 0.0f),
        heat);
}

extern "C"
void set_texture_filter_mode(bool bLinearFilter)
{
    density_tex.filterMode = bLinearFilter ? cudaFilterModeLinear : cudaFilterModePoint;
}

extern "C"
void init_cuda(void *h_volume, cudaExtent volumeSize)
{
    // create 3D array
    cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<VolumeType>();
    checkCudaErrors(cudaMalloc3DArray(&d_volumeArray, &channelDesc, volumeSize));

    // copy data to 3D array
    cudaMemcpy3DParms copyParams = {0};
    copyParams.srcPtr   = make_cudaPitchedPtr(h_volume,
        volumeSize.width * sizeof(VolumeType), volumeSize.width, volumeSize.height);
    copyParams.dstArray = d_volumeArray;
    copyParams.extent   = volumeSize;
    copyParams.kind     = cudaMemcpyHostToDevice;
    checkCudaErrors(cudaMemcpy3D(&copyParams));

    // set texture parameters
    density_tex.normalized = true;                      // access with normalized texture coordinates
    density_tex.filterMode = cudaFilterModeLinear;      // linear interpolation
    density_tex.addressMode[0] = cudaAddressModeClamp;  // clamp texture coordinates
    density_tex.addressMode[1] = cudaAddressModeClamp;

    // bind array to 3D texture
    checkCudaErrors(cudaBindTextureToArray(density_tex, d_volumeArray, channelDesc));
}

extern "C"
void copy_inv_view_matrix(float *invViewMatrix, size_t sizeofMatrix)
{
    checkCudaErrors(cudaMemcpyToSymbol(c_invViewMatrix, invViewMatrix, sizeofMatrix));
}

extern "C"
void free_cuda_buffers()
{
    checkCudaErrors(cudaFreeArray(d_volumeArray));
}



namespace XORShift
{ 
    // XOR shift PRNG
    unsigned int x = 123456789;
    unsigned int y = 362436069;
    unsigned int z = 521288629;
    unsigned int w = 88675123;
    inline unsigned int frand()
    {
        unsigned int t;
        t = x ^ (x << 11);
        x = y; y = z; z = w;
        return (w = (w ^ (w >> 19)) ^ (t ^ (t >> 8)));
    }
}

__global__
void __init_rng(CudaRng *rng, int width, int height, unsigned int *seeds)
{
    uint x = blockIdx.x * blockDim.x + threadIdx.x;
    uint y = blockIdx.y * blockDim.y + threadIdx.y;

    if ((x >= width) || (y >= height))
    {
        return;
    }

    int idx = x + y * width;
    rng[idx].init(seeds[idx]);
}

extern "C"
void init_rng(dim3 gridSize, dim3 blockSize, int width, int height)
{
    cout << "init cuda rng to " << width << " x " << height << endl;
    unsigned int *seeds;
    checkCudaErrors(cudaMallocManaged(&seeds, sizeof(unsigned int) * width * height));
    checkCudaErrors(cudaDeviceSynchronize());
    for (int i = 0; i < width * height; ++i)
    {
        seeds[i] = XORShift::frand();
    }

    checkCudaErrors(cudaDeviceSynchronize());
    checkCudaErrors(cudaMalloc(&cuda_rng, sizeof(CudaRng) * width * height));
    __init_rng << <gridSize, blockSize >> >(cuda_rng, width, height, seeds);
    checkCudaErrors(cudaFree(seeds));
}

extern "C"
void free_rng()
{
    cout << "free cuda rng" << endl;
    checkCudaErrors(cudaFree(cuda_rng));
}

extern "C"
void render_kernel(dim3 gridSize, dim3 blockSize, float4 *d_output, const Param& p)
{
    __d_render<<<gridSize, blockSize>>>(d_output, cuda_rng, p);
}

__global__
void __scale(float4 *dst, float4 *src, int size, float scale)
{
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx >= size)
    {
        return;
    }
    dst[idx] = src[idx] * scale;
}

extern "C"
void scale(float4 *dst, float4 *src, int size, float scale)
{
    __scale << <(size + 256 - 1) / 256, 256 >> >(dst, src, size, scale);
}

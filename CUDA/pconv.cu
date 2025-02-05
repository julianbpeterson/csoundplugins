// -*- c++ -*-
/* pconv.cu
  (c) Victor Lazzarini, 2013

  This file is part of Csound.

  The Csound Library is free software; you can redistribute it
  and/or modify it under the terms of the GNU Lesser General Public
  License as published by the Free Software Foundation; either
  version 2.1 of the License, or (at your option) any later version.

  Csound is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU Lesser General Public License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with Csound; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
  02110-1301 USA
*/
#include <csdl.h>
#include <cufft.h>

/* 
  each kernel processes one bin 
*/
__global__ void pconvol(float *out,float *in, 
			float *coef,int rp, int dftsize, 
			int nparts, int end) {
  float re,im,re2,im2;   

  /* thread count */
  int t = (threadIdx.x + blockIdx.x*blockDim.x);

  int k = t<<1;       /* coef pos      */   
  int n = k%(dftsize+2);  /* inframe pos   */

  /* if beyond the buffer end, exit */
  if(k >= end) return;                  
  rp += k/(dftsize+2);       /*  rp pos */

  /* select correct input buffer */
  in += (rp < nparts ? rp : rp%nparts)*(dftsize+2);

  re = coef[k]; im = coef[k+1];
  re2 = in[n];  im2 = in[n+1];
  
  /* complex multiplication + sums */
  atomicAdd(&out[n], re*re2 - im*im2);
  (n || n != dftsize) ? atomicAdd(&out[n+1], re*im2 + re2*im) : im;
 
}  

/* sample-by-sample overlap-add operation */
__global__ void olapadd(float *buf, float *in, int parts){
   int n = (threadIdx.x + blockIdx.x*blockDim.x);
   buf[n] = in[n] + buf[parts+n];
   buf[parts+n] = in[parts+n];
}



typedef struct _pconv{
  OPDS h;
  MYFLT *aout, *asig, *ifn, *parts;
  float *out, *coef, *in, *buf;
  AUXCH  bufin, bufout;
  int wp, nparts, dftsize, cnt;
  cufftHandle plan, iplan;
  int threads, blocks, othreads, oblocks;
} PCONV;


int isPowerOfTwo (unsigned int x)
{
  return ((x != 0) && !(x & (x - 1)));
}


static int destroy_pconv(CSOUND *csound, void *pp){
  PCONV *p = (PCONV *) pp;
  cufftDestroy(p->plan);
  cufftDestroy(p->iplan);
  cudaFree(p->coef);
  cudaFree(p->in);
  cudaFree(p->out);
  cudaFree(p->buf);
  return OK;
}


int pconv_init(CSOUND *csound, PCONV *p){

  FUNC *ftab = csound->FTnp2Find(csound, p->ifn);
  float *tmp;
  int tlen = ftab->flen;
  int end, i, j, k, parts = *p->parts, dftsize, nparts;
  MYFLT *tab = ftab->ftable;

  if(!isPowerOfTwo(parts))
    return csound->InitError(csound, "partition size needs to be power of two\n");

  if(parts > tlen)
     return csound->InitError(csound, "partition size too big \n");

  end = tlen + parts - 1;

  nparts = end / parts;
  dftsize = parts << 1;
  end = nparts*(dftsize+2);

  cudaMalloc(&p->coef, sizeof(float)*end);   
  cudaMalloc(&p->in, sizeof(float)*end); 
  cudaMalloc(&p->out, sizeof(float)*(dftsize+2)); 
  cudaMalloc(&p->buf, sizeof(float)*(dftsize)); 
  cudaMemset(p->in,0,sizeof(float)*end);
  cudaMemset(p->out, 0, sizeof(float)*(dftsize+2));
  cudaMemset(p->buf, 0, sizeof(float)*(dftsize));
  cudaMemset(p->coef, 0, sizeof(float)*end);

  p->wp = 0;

  if(!p->bufin.auxp || p->bufin.size < sizeof(float)*dftsize)
     csound->AuxAlloc(csound, sizeof(float)*dftsize, &p->bufin);
  if(!p->bufout.auxp || p->bufout.size < sizeof(float)*parts)
     csound->AuxAlloc(csound, sizeof(float)*parts, &p->bufout);

  memset(p->bufout.auxp, 0, sizeof(float)*parts);

  tmp = (float *) p->bufin.auxp;
  cufftPlan1d(&p->plan, dftsize, CUFFT_R2C, 1);
#if __CUDACC_VER_MAJOR__ < 8
  cufftSetCompatibilityMode(p->plan, CUFFT_COMPATIBILITY_NATIVE);
#endif
  cufftPlan1d(&p->iplan, dftsize, CUFFT_C2R, 1);
#if __CUDACC_VER_MAJOR__ < 8
  cufftSetCompatibilityMode(p->iplan, CUFFT_COMPATIBILITY_NATIVE);
#endif

  for(i =0, k=0; i < nparts; i++){
    for(j=0; j < dftsize; j++)
      tmp[j] = j < parts && k < tlen ? tab[k++] : 0.f;
      float *pp = p->coef + (nparts - 1 - i)*(dftsize+2);
    cudaMemcpy(pp, tmp, sizeof(float)*dftsize, 
               cudaMemcpyHostToDevice);
    // csound->Message(csound,"CUDA init: copy buffer %d to device\n",i);
    cufftExecR2C(p->plan,pp,(cufftComplex*)pp);
    //csound->Message(csound,"CUDA init: done transform %d\n",i);
   }

  cudaDeviceSynchronize();
  cudaDeviceProp deviceProp;
  cudaGetDeviceProperties(&deviceProp, 0);
  int blockspt = deviceProp.maxThreadsPerBlock;
  csound->Message(csound, "CUDApconv: using device %s (capability %d.%d)\n",
        deviceProp.name,deviceProp.major, deviceProp.minor);
  
 
  end >>= 1;

  p->blocks = end > blockspt ? ceil(end/blockspt) : 1;
  p->threads = end > blockspt ? blockspt : end;
  p->oblocks = parts > blockspt ? ceil(parts/blockspt) : 1;
  p->othreads = parts > blockspt ? blockspt : parts;

  csound->RegisterDeinitCallback(csound, p, destroy_pconv);

  OPARMS parms;
  csound->GetOParms(csound, &parms);
  if(parms.odebug)
   csound->Message(csound, 
     "blocks %d - threads/block %d - threads %d - dftsize %d - parts %d\n", 
		   p->blocks, p->threads, end, dftsize, nparts);

  p->nparts = nparts;
  p->dftsize = dftsize;
  p->cnt = 0;

  return OK;
}

int pconv_perf(CSOUND *csound, PCONV *p){

  int dftsize = p->dftsize, cnt = p->cnt, wp = p->wp, nparts = p->nparts;
  uint32_t offset = p->h.insdshead->ksmps_offset;
  uint32_t early  = p->h.insdshead->ksmps_no_end;
  uint32_t n, nsmps = CS_KSMPS;
  float *bufin = (float *) p->bufin.auxp, *bufout = (float *) p->bufout.auxp;
  MYFLT *asig = p->asig, *aout = p->aout;
  float *in = p->in, *out = p->out, *coef = p->coef, *buf = p->buf;
  int end = nparts*(dftsize+2);
  int parts = *p->parts;

  if (UNLIKELY(offset)) memset(asig, '\0', offset*sizeof(MYFLT));
  if (UNLIKELY(early)) {
    nsmps -= early;
    memset(&asig[nsmps], '\0', early*sizeof(MYFLT));
  }

  //csound->Message(csound,"pconv perf count: %d\n", cnt);  
  for(n = offset; n < nsmps; n++){
    bufin[cnt] = (float) asig[n];
    aout[n] = (MYFLT) bufout[cnt]/dftsize;
  
    if(++cnt == parts){
      //csound->Message(csound,"CUDA execution:\n");
       /* in buffer pos */
      int pos = wp*(dftsize+2);

       /* increment delay line pos
          so that it points to the oldest partition
       */
       wp += 1;
       if(wp == nparts) wp = 0;

       /* copy current buffer into newest partition */
       cudaMemset(out, 0, sizeof(float)*(dftsize+2));
       cudaMemcpy(&in[pos],bufin,sizeof(float)*dftsize,cudaMemcpyHostToDevice);
       //csound->Message(csound,"done copy to device\n");

       /* apply transform */
       if(cufftExecR2C(p->plan,&in[pos],(cufftComplex*)&in[pos])
        != CUFFT_SUCCESS) csound->Message(csound, "cuda fft error\n");
       if (cudaDeviceSynchronize() != cudaSuccess)
        csound->Message(csound,"Cuda error: Failed to synchronize\n");
       //csound->Message(csound,"done transform\n");

       /* convolution */
       pconvol<<<p->blocks,p->threads>>>(out, in, coef, wp, dftsize, nparts, end);
       if (cudaDeviceSynchronize() != cudaSuccess)
        csound->Message(csound,"Cuda error: Failed to synchronize\n");
       //csound->Message(csound,"done convolution\n");

       /* transform output */
       if(cufftExecC2R(p->iplan,(cufftComplex*)out,out) 
          != CUFFT_SUCCESS) csound->Message(csound, "cuda fft error\n");
       //csound->Message(csound,"done inverse transform\n");

       /* overlap-add */
       olapadd<<<p->oblocks,p->othreads>>>(buf,out,parts);
       //csound->Message(csound,"done overlap-add\n");
 
       /* copy buffer out */
       cudaMemcpy(bufout,buf, sizeof(float)*parts,cudaMemcpyDeviceToHost);
       //csound->Message(csound,"done copy from device\n");

       cnt = 0;
    }
  }
  p->cnt = cnt;
  p->wp = wp;
  return OK;
}

static OENTRY localops[] = {
  {"cudapconv", sizeof(PCONV),0, 3, "a", "aii", (SUBR) pconv_init, 
    (SUBR) pconv_perf},
};

extern "C" {
  LINKAGE
}

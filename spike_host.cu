/*******************************************************************************************************
                              University of Illinois/NCSA Open Source License
                                 Copyright (c) 2012 University of Illinois
                                          All rights reserved.

                                        Developed by: IMPACT Group
                                          University of Illinois
                                      http://impact.crhc.illinois.edu

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal with the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

  Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimers.
  Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimers in the documentation and/or other materials provided with the distribution.
  Neither the names of IMPACT Group, University of Illinois, nor the names of its contributors may be used to endorse or promote products derived from this Software without specific prior written permission.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH THE SOFTWARE.

*******************************************************************************************************/


#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <device_functions.h>
#include "datablock.h"
#include "spike_kernel.hxx"

template <typename T, typename T_REAL> 
void gtsv_spike_partial_diag_pivot(Datablock<T, T_REAL> *data, const T* dl, const T* d, const T* du, T* b, const int m)
{
	printf("\nRunning GTSV SPIKE.\n");
	
	// prefer larger L1 cache and smaller shared memory
	cudaFuncSetCacheConfig(tiled_diag_pivot_x1<T,T_REAL>,cudaFuncCachePreferL1);
	cudaFuncSetCacheConfig(spike_GPU_back_sub_x1<T>,cudaFuncCachePreferL1);
	
	// variables for finding no of 1 by 1 pivotings
	int *h_pivotingData;
	int *pivotingData;

    	h_pivotingData = (int *)malloc(sizeof(int));
	checkCudaErrors(cudaMalloc((void **)&pivotingData, sizeof(int)));
    	checkCudaErrors(cudaMemset((void *)pivotingData, 0, sizeof(int)));

    	T* dl_buffer 	= data->dl_buffer;  	// lower digonal after DM
	T* d_buffer  	= data->d_buffer;  	// digonal after DM
	T* du_buffer	= data->du_buffer; 	// upper diagonal after DM
	T* b_buffer	= data->b_buffer;	// B array after DM (here, B is in Ax = B)
	T* w_buffer	= data->w_buffer;	// W in A_i * W_i = vector w/ partition's lower diagonal element
	T* v_buffer	= data->v_buffer;	// V in A_i * V_i = vector w/ partition's upper diagonal element
	T* c2_buffer	= data->c2_buffer;	// stores modified diagonal elements in diagonal pivoting method
	bool *flag	= data->flag; 
    
	T* x_level_2 = data->x_level_2;
	T* w_level_2 = data->w_level_2;
	T* v_level_2 = data->v_level_2;

	int local_reduction_share_size	= data->local_reduction_share_size; 	
	int global_share_size		= data->global_share_size;		
	int local_solving_share_size	= data->local_solving_share_size;
	int marshaling_share_size	= data->marshaling_share_size;

	dim3 gridDim  = data->gridDim;
	dim3 blockDim = data->blockDim;

	int s 		= data->s;
	int b_dim	= data->b_dim;
	int stride	= data->h_stride;
	int tile 	= 128;
    	
	// T* d_gammaLeft;
	// T* d_gammaRight;
	// T* dx_2Inv;
	// T* d_dx_2Inv;

	// cudaMalloc((void **)&d_gammaLeft, sizeof(T));
	// cudaMalloc((void **)&d_gammaRight, sizeof(T));
	// cudaMalloc((void **)&d_dx_2Inv, sizeof(T_REAL));

	//kernels 
	//data layout transformation
	forward_marshaling_bxb<T><<<gridDim, blockDim, marshaling_share_size>>>(dl_buffer, dl, stride, b_dim, m, cuGet<T>(0));
	forward_marshaling_bxb<T><<<gridDim, blockDim, marshaling_share_size>>>(d_buffer,  d,  stride, b_dim, m, cuGet<T>(1));
	forward_marshaling_bxb<T><<<gridDim, blockDim, marshaling_share_size>>>(du_buffer, du, stride, b_dim, m, cuGet<T>(0));
	forward_marshaling_bxb<T><<<gridDim, blockDim, marshaling_share_size>>>(b_buffer,  b,  stride, b_dim, m, cuGet<T>(0));
	 
	// partitioned solver
	// tiled_diagonal_pivoting<<<s,b_dim>>>(x, w, v, c2_buffer, flag, dl,d,du,b, stride,tile);
	tiled_diag_pivot_x1<T,T_REAL><<<s, b_dim>>>(b_buffer, w_buffer, v_buffer, c2_buffer, flag, dl_buffer, d_buffer, du_buffer, stride, tile, pivotingData);
	
	// SPIKE solver
	spike_local_reduction_x1<T><<<s, b_dim, local_reduction_share_size>>>(b_buffer, w_buffer, v_buffer, x_level_2, w_level_2, v_level_2, stride);
	spike_GPU_global_solving_x1<<<1, 32, global_share_size>>>(x_level_2, w_level_2, v_level_2, s);
	spike_GPU_local_solving_x1<T><<<s, b_dim, local_solving_share_size>>>(b_buffer, w_buffer, v_buffer, x_level_2, stride);
	spike_GPU_back_sub_x1<T><<<s, b_dim>>>(b_buffer, w_buffer, v_buffer, x_level_2, stride);

	back_marshaling_bxb<T><<<gridDim, blockDim, marshaling_share_size>>>(b, b_buffer, stride, b_dim, m);
	// cudaMemcpy(h_gammaLeft, d_gamma)
	cudaMemcpy(h_pivotingData, pivotingData, sizeof(int), cudaMemcpyDeviceToHost);
	printf("No of 1 by 1 pivotings done = %d.\n", *h_pivotingData);
	printf("Solving done.\n\n");
	// free pivotingData both h and dev
}

template <typename T, typename T_REAL> 
void gtsv_spike_partial_diag_pivot(const T* dl, const T* d, const T* du, T* b, const int m);
/* explicit instanciation */
template void gtsv_spike_partial_diag_pivot<cuComplex, float>(Datablock<cuComplex, float> *data, const cuComplex* dl, const cuComplex* d, const cuComplex* du, cuComplex* b,const int m);
template void gtsv_spike_partial_diag_pivot<cuDoubleComplex, double>(Datablock<cuDoubleComplex, double> *data, const cuDoubleComplex* dl, const cuDoubleComplex* d, const cuDoubleComplex* du, cuDoubleComplex* b, const int m);

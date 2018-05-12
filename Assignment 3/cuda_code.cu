#include <stdio.h>
#include <iostream>
#include <string>

#include "results.h"

// Globals used when setting up and timing kernels
cudaEvent_t f_start, f_stop, f_copy_start, f_copy_stop;
cudaEvent_t d_start, d_stop, d_copy_start, d_copy_stop;
cudaStream_t float_stream, double_stream;
int double_device_id, float_device_id;
float *device_float_results;
double *device_double_results;
extern struct cuda_results_s timings;

#define THREADS_PER_N 20

void custom_error_check(cudaError result, std::string err_str){
	if(result != cudaSuccess){
		std::cout << err_str << "\n";
		std::cout << "Error code: " << result << "\n";
		exit(1);
	}	
}

// Should be called AFTER set_devices()
void init_events_and_streams(){
	// Float events and streams
	cudaSetDevice(float_device_id);
	cudaEventCreate(&f_start);
	cudaEventCreate(&f_stop);
	cudaEventCreate(&f_copy_start);
	cudaEventCreate(&f_copy_stop);
	cudaStreamCreate(&float_stream);
	// Double events and streams
	cudaSetDevice(double_device_id);
	cudaEventCreate(&d_start);
	cudaEventCreate(&d_stop);
	cudaEventCreate(&d_copy_start);
	cudaEventCreate(&d_copy_stop);
	cudaStreamCreate(&double_stream);
}

void allocate_float_results(unsigned int size){
	cudaSetDevice(float_device_id);
	cudaEventRecord(f_start, float_stream);
	custom_error_check(
		cudaMalloc((void **) &device_float_results, size * sizeof(float)), 
		"Failed to allocate float result buffer on device."
	);
	cudaEventRecord(f_stop, float_stream);
	cudaEventSynchronize(f_stop);
	cudaEventElapsedTime(&timings.float_alloc_time, f_start, f_stop);
}

void allocate_double_results(unsigned int size){
	cudaSetDevice(double_device_id);
	cudaEventRecord(d_start, double_stream);
	custom_error_check(
		cudaMalloc((void **) &device_double_results, size * sizeof(double)), 
		"Failed to allocate double result buffer on device."
	);
	cudaEventRecord(d_stop, double_stream);
	cudaEventSynchronize(d_stop);
	cudaEventElapsedTime(&timings.double_alloc_time, d_start, d_stop);
}

void copy_results_from_device(float **float_results, double **double_results, unsigned int size){
	cudaSetDevice(float_device_id);
	cudaEventRecord(f_copy_start, float_stream);
	custom_error_check(
		cudaMemcpyAsync(float_results[0], device_float_results, size * sizeof(float), cudaMemcpyDeviceToHost, float_stream), 
		"Failed to copy float results from device."
	);
	cudaEventRecord(f_copy_stop, float_stream);

	cudaSetDevice(double_device_id);
	cudaEventRecord(d_copy_start, double_stream);
	custom_error_check(
		cudaMemcpyAsync(double_results[0], device_double_results, size * sizeof(double), cudaMemcpyDeviceToHost, double_stream), 
		"Failed to copy double results from device."
	);
	cudaEventRecord(d_copy_stop, double_stream);
	// Free device pointers
	cudaSetDevice(float_device_id);
	custom_error_check(
		cudaFree(device_float_results), 
		"Failed to free float results on device"
	);
	cudaEventSynchronize(f_copy_stop);
	cudaEventElapsedTime(&timings.float_copy_time, f_copy_start, f_copy_stop);

	cudaSetDevice(double_device_id);
	custom_error_check(
		cudaFree(device_double_results), 
		"Failed to double results on device"
	);
	cudaEventSynchronize(d_copy_stop);
	cudaEventElapsedTime(&timings.double_copy_time, d_copy_start, d_copy_stop);


}

// Adapted from provided sample code
void set_devices() {
	int i,n,best,bestNumberOfMultiprocessors;
	cudaGetDeviceCount(&n);
	int numberOfCUDAcoresForThisCC=0;
	struct cudaDeviceProp x;
	best=-1;
	bestNumberOfMultiprocessors=-1;
	for (i=0;i<n;i++) {
		cudaGetDeviceProperties(&x, i);
		switch (x.major) {
			case 1:	// Tesla / T10
				numberOfCUDAcoresForThisCC=8;
				break;
			case 2:	// Fermi
				numberOfCUDAcoresForThisCC=32;
				break;
			case 3:	// Kepler
				numberOfCUDAcoresForThisCC=192;
				break;
			case 5:	// Maxwell
				numberOfCUDAcoresForThisCC=128;
				break;
			case 6:	// Pascal
				switch (x.minor) {
					case 0: // GP100, 64 cuda cores per SM - 7.0 should be prefered over 7.1
						numberOfCUDAcoresForThisCC=64;
						break;
					case 1: // GP102, GP104, GP106, GP107, 128 cuda cores per SM
						numberOfCUDAcoresForThisCC=128;
						break;
					default: // Unknown
						numberOfCUDAcoresForThisCC=0;
						break;
				}
				numberOfCUDAcoresForThisCC=128;
				break;
			case 7:	// Volta
				numberOfCUDAcoresForThisCC=64;
				break;
			default: // Unknown
				numberOfCUDAcoresForThisCC=0;
				break;
		}
		if (x.multiProcessorCount>bestNumberOfMultiprocessors*numberOfCUDAcoresForThisCC) {
			best=i;
			bestNumberOfMultiprocessors=x.multiProcessorCount*numberOfCUDAcoresForThisCC;
		}
	}
	double_device_id = best;
	float_device_id = double_device_id == 0 ? 1 : 0;
}

__device__ float device_exp_integral_float(const int n, const float x){
	const int max_iter = 2000000000;
	const float e_const_float = 0.5772156649015329f;
	const float epsilon_float = 1.E-30f;
	int i, ii, nm1 = n-1;
	float a, b, c, d, del, fact, h, psi, ans=0.0;
	if(n == 0){
		return expf(-x)/x;
	}
	if(x > 1.0f){
		b = x + n;
		c = 3.402823E38;
		d = 1.0f/b;
		h=d;
		for(i = 1; i <= max_iter; i++){
			a=-i*(nm1+i);
			b+=2.0;
			d=1.0/(a*d+b);
			c=b+a/c;
			del=c*d;
			h*=del;
			if (fabsf(del-1.0)<=epsilon_float) {
				return h*expf(-x);
			}
		}
                return h*expf(-x);
	} else {
		ans=(nm1!=0 ? 1.0/nm1 : -log(x)-e_const_float); // First term
		fact=1.0;
		for (i=1;i<=max_iter;i++) {
			fact*=-x/i;
			if (i != nm1) {
				del = -fact/(i-nm1);
			} else {
				psi = -e_const_float;
				for (ii=1;ii<=nm1;ii++) {
					psi += 1.0/ii;
				}
				del=fact*(-log(x)+psi);
			}
			ans+=del;
			if (fabsf(del)<fabsf(ans)*epsilon_float) return ans;
		}
		return ans;
	}
}

// Note: need to use j-1 as an index since j starts at 1 rather than 0
// Same with using idx rather than my_n, as the minimum my_n is 1 rather than 0.
// TODO: move variables (like division) to constant memory to save registers
__global__ void device_part_float(
		const float division, const int n, const int num_samples, const float a, 
		float *device_float_results
	){
	const int idx=blockIdx.x*blockDim.x+threadIdx.x;
	const int my_n = (idx/THREADS_PER_N) + 1;
	if(my_n > n){
		return;
	}
	const int offset = ((my_n - 1) * num_samples);
	int j;
	int start = ((num_samples / THREADS_PER_N) * (idx % THREADS_PER_N)) + 1;
	int limit = (num_samples / THREADS_PER_N) * ((idx % THREADS_PER_N) + 1);
	if(idx % THREADS_PER_N == THREADS_PER_N - 1){
		limit = num_samples;
	}	
	float x;
	float4 f_res;
	for(j = start; j <= limit - 4; j = j + 4){
		x = a+(j*division);
		f_res.x = device_exp_integral_float(my_n, x);
		x = a+((j+1)*division);
		f_res.y = device_exp_integral_float(my_n, x);
		x = a+((j+2)*division);
		f_res.z = device_exp_integral_float(my_n, x);
		x = a+((j+3)*division);
		f_res.w = device_exp_integral_float(my_n, x);
		*((float4 *)&(device_float_results[offset + (j-1)])) = f_res;
	}	
	// Handle any remaining work if num_samples does not divide evenly by 4
	for(; j <= limit; j++){
                x = a+(j*division);
                f_res.x = device_exp_integral_float(my_n, x);
		device_float_results[offset + (j-1)] = f_res.x;
	}
}

__device__ double device_exp_integral_double(int n, const double x){
	const int max_iter = 2000000000;
	const double e_const_double = 0.5772156649015329;
	const double epsilon_double = 1.E-30;
	int i, ii = n-1;
	double a, b, c, d, del, fact, h, psi, ans=0.0;
	if(n == 0){
		return exp(-x)/x;
	}
	if(x > 1.0f){
		b = x + n;
		c = 3.402823E38;
		d = 1.0f/b;
		h=d;
		for(i = 1; i <= max_iter; i++){
			a=-i*(n-1+i);
			b+=2.0;
			d=1.0/(a*d+b);
			c=b+a/c;
			del=c*d;
			h*=del;
			if (fabs(del-1.0)<=epsilon_double) {
				return h*exp(-x);
			}
		}
                return h*exp(-x);
	} else {
		ans=(n-1!=0 ? 1.0/(n-1) : -log(x)-e_const_double); // First term
		fact=1.0;
		for (i=1;i<=max_iter;i++) {
			fact*=-x/i;
			if (i != (n-1)) {
				del = -fact/(i-(n-1));
			} else {
				psi = -e_const_double;
				for (ii=1;ii<=n-1;ii++) {
					psi += 1.0/ii;
				}
				del=fact*(-log(x)+psi);
			}
			ans+=del;
			if (fabs(del)<fabs(ans)*epsilon_double) return ans;
		}
		return ans;
	}
}

__constant__ double d_division;
__constant__ int d_n;
__constant__ int d_num_samples;
__constant__ double d_a;
__constant__ double *d_device_double_results;

__shared__ double thread_xs[1024];
__shared__ int block_n;

// Note: need to use j-1 as an index since j starts at 1 rather than 0
// Same with using idx rather than my_n, as the minimum my_n is 1 rather than 0.
// TODO: move variables (like division) to constant memory to save registers
__global__ void device_part_double(){
	if(threadIdx.x + (blockIdx.x * blockDim.x) >= d_num_samples){
		return;
	}
	int my_sample = (threadIdx.x + (blockIdx.x * blockDim.x)) + 1;
	double my_x = d_a + (my_sample * d_division);
	//printf("Thread idx: %d has x id %d in block with x = %d and y = %d and taking sample %d with value %f\n",
	//	idx, threadIdx.x, blockIdx.x, blockIdx.y, my_sample, my_x);
	
	for(int j = blockIdx.y + 1; j <= d_n; j = j + gridDim.y){
		d_device_double_results[((j-1) * d_num_samples) + (my_sample-1)]
			= device_exp_integral_double(j, my_x);
	}
}

// TODO: fix up events and record to a struct rather than printing info here
// Assuming this is run on CUDA01 it does the following:
//	1) The float code is run on the GTX 780
//	2) The double code is run on the Tesla K40c
extern void do_cuda_part(
		double a, double b, unsigned int n, unsigned int num_samples, 
		int block_size, float **float_results, double **double_results
	){
	// Data needed by both kernels
	unsigned int size = n * num_samples;
	double division = (b-a)/(double)num_samples;
	dim3 dimBlock_f(block_size);
	dim3 dimGrid_f ( ((n*THREADS_PER_N)/dimBlock_f.x) + (!((n*THREADS_PER_N)%dimBlock_f.x)?0:1) );

	dim3 dimBlock(block_size, 1);
	dim3 dimGrid ( (n/dimBlock.x) + (!((n)%dimBlock.x)?0:1), THREADS_PER_N );

	set_devices();
	init_events_and_streams();
	allocate_float_results(size);
	allocate_double_results(size);

	// Allocate constants for double kernel
	cudaSetDevice(double_device_id);
	cudaMemcpyToSymbolAsync(d_division, &division, sizeof(double), 0, cudaMemcpyHostToDevice,  double_stream);
	//cudaMemcpyToSymbolAsync(d_block_size, &block_size, sizeof(double), 0, cudaMemcpyHostToDevice,  double_stream);
	cudaMemcpyToSymbolAsync(d_n, &n, sizeof(int), 0, cudaMemcpyHostToDevice, double_stream);
	cudaMemcpyToSymbolAsync(d_num_samples, &num_samples, sizeof(int), 0, cudaMemcpyHostToDevice, double_stream);
	cudaMemcpyToSymbolAsync(d_a, &a, sizeof(double), 0, cudaMemcpyHostToDevice, double_stream);
	cudaMemcpyToSymbolAsync(d_device_double_results, &device_double_results, sizeof(double *), 0, cudaMemcpyHostToDevice,  double_stream);
	
	
	// Now run the kernels on different streams
	cudaSetDevice(float_device_id);
	cudaEventRecord(f_start, float_stream);
	device_part_float<<<dimGrid_f,dimBlock_f, 0, float_stream>>>((float)division, n, num_samples, (float)a, device_float_results);
	cudaEventRecord(f_stop, float_stream);
	cudaSetDevice(double_device_id);
	cudaEventRecord(d_start, double_stream);
	device_part_double<<<dimGrid,dimBlock, 0, double_stream>>>();
	cudaEventRecord(d_stop, double_stream);

	// Async copy results
	copy_results_from_device(float_results, double_results, size);

	cudaEventSynchronize(f_stop);
	cudaEventElapsedTime(&timings.float_kernel_time, f_start, f_stop);

	cudaEventSynchronize(d_stop);
	cudaEventElapsedTime(&timings.double_kernel_time, d_start, d_stop);

	// Destroy streams
	cudaStreamDestroy(float_stream);
	cudaStreamDestroy(double_stream);
}

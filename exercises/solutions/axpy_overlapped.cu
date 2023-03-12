#include <stdio.h>
#include "../cuda_helpers.cuh"


/*
 axpy kernel function
*/
__global__ void axpy(const float a, const float* X, const float* Y, float* Z, const int N) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < N) Z[idx] = a * X[idx] + Y[idx];
}


/*
  Manage a collection of streams
*/
typedef struct {
  int n_streams;
  cudaStream_t* streams;
} Streams;

// Create enough streams for chunks of STREAM_SIZE in N
Streams create_streams(const int N, const int STREAM_SIZE) {
  const int N_STREAMS = (N + STREAM_SIZE - 1) / STREAM_SIZE;
  cudaStream_t* streams = (cudaStream_t*)malloc(sizeof(*streams)*N_STREAMS);
  for (int i = 0; i < N_STREAMS; ++i) {
    cudaStreamCreate(&streams[i]);
  }
  cuda_check(cudaGetLastError());
  
  return {
    .n_streams = N_STREAMS,
    .streams = streams,
  };
}

// Destroy streams and clean up memory
void destroy_streams(Streams streams) {
  for (int i = 0; i < streams.n_streams; ++i) {
    cudaStreamDestroy(streams.streams[i]);
  }
  free(streams.streams);
}



/*
  Run the axpy function:
    - Copy X and Y to the device
    - Run the kernel
    - Copy Z back to the host
  TODO: MODIFY THIS FUNCTION TO USE OVERLAPPING STREAMS.
        Don't forget to call cudaStreamDestroy at the end!
*/

// PER_STREAM:
//  0 = launch all streams of one operation before starting on next (default)
//  1 = launch all operations in a stream before moving to next stream
#ifndef PER_STREAM
#define PER_STREAM 0
#endif
#if PER_STREAM == 1
void run_axpy(
  const float a, 
  float* X, float* X_d,
  const float* Y, float* Y_d,
  float* Z, float* Z_d,
  const int N,
  Streams s, const int STREAM_SIZE
) {
  int offset;
  for (int i = 0; i < s.n_streams - 1; ++i) {
    offset = i * STREAM_SIZE;
    // Copy X and Y to the GPU
    cudaMemcpyAsync(
      &X_d[offset], &X[offset], sizeof(*X)*STREAM_SIZE,
      cudaMemcpyHostToDevice, s.streams[i]);
    cudaMemcpyAsync(
      &Y_d[offset], &Y[offset], sizeof(*Y)*STREAM_SIZE,
      cudaMemcpyHostToDevice, s.streams[i]);

    // Call the axpy kernel with at least N threads
    axpy<<<DEF_GRID(STREAM_SIZE), DEF_BLOCK, 0, s.streams[i]>>>(
      a, &X_d[offset], &Y_d[offset], &Z_d[offset], STREAM_SIZE);

    // Copy the result back into Z
    cudaMemcpyAsync(
      &Z[offset], &Z_d[offset], sizeof(*Z)*STREAM_SIZE,
      cudaMemcpyDeviceToHost, s.streams[i]);
  }
  // Handle final chunk in case N isn't a multiple of STREAM_SIZE
  offset = (s.n_streams - 1) * STREAM_SIZE;
  cudaMemcpyAsync(
    &X_d[offset], &X[offset], sizeof(*X)*(N-offset),
    cudaMemcpyHostToDevice, s.streams[s.n_streams-1]);
  cudaMemcpyAsync(
    &Y_d[offset], &Y[offset], sizeof(*Y)*(N-offset),
    cudaMemcpyHostToDevice, s.streams[s.n_streams-1]);
  axpy<<<DEF_GRID(N-offset), DEF_BLOCK, 0, s.streams[s.n_streams-1]>>>(
    a, &X_d[offset], &Y_d[offset], &Z_d[offset], N-offset);
  cudaMemcpyAsync(
    &Z[offset], &Z_d[offset], sizeof(*Z)*(N-offset),
    cudaMemcpyDeviceToHost, s.streams[s.n_streams-1]);
    
  cuda_check(cudaGetLastError());
  cuda_check(cudaDeviceSynchronize());
}

#else

void run_axpy(
  const float a, 
  float* X, float* X_d,
  const float* Y, float* Y_d,
  float* Z, float* Z_d,
  const int N,
  Streams s, const int STREAM_SIZE
) {
  int offset;
  for (int i = 0; i < s.n_streams - 1; ++i) {
    offset = i * STREAM_SIZE;
    // Copy X and Y to the GPU
    cudaMemcpyAsync(
      &X_d[offset], &X[offset], sizeof(*X)*STREAM_SIZE,
      cudaMemcpyHostToDevice, s.streams[i]);
  }
  offset = (s.n_streams - 1) * STREAM_SIZE;
  cudaMemcpyAsync(
    &X_d[offset], &X[offset], sizeof(*X)*(N-offset),
    cudaMemcpyHostToDevice, s.streams[s.n_streams-1]);
    
  for (int i = 0; i < s.n_streams - 1; ++i) {
    offset = i * STREAM_SIZE;
    cudaMemcpyAsync(
      &Y_d[offset], &Y[offset], sizeof(*Y)*STREAM_SIZE,
      cudaMemcpyHostToDevice, s.streams[i]);
  }
  offset = (s.n_streams - 1) * STREAM_SIZE;
  cudaMemcpyAsync(
    &Y_d[offset], &Y[offset], sizeof(*Y)*(N-offset),
    cudaMemcpyHostToDevice, s.streams[s.n_streams-1]);
  
  for (int i = 0; i < s.n_streams - 1; ++i) {
    offset = i * STREAM_SIZE;
    // Call the axpy kernel with at least N threads
    axpy<<<DEF_GRID(STREAM_SIZE), DEF_BLOCK, 0, s.streams[i]>>>(
      a, &X_d[offset], &Y_d[offset], &Z_d[offset], STREAM_SIZE);
  }
  offset = (s.n_streams - 1) * STREAM_SIZE;
  axpy<<<DEF_GRID(N-offset), DEF_BLOCK, 0, s.streams[s.n_streams-1]>>>(
    a, &X_d[offset], &Y_d[offset], &Z_d[offset], N-offset);
  
  for (int i = 0; i < s.n_streams - 1; ++i) {
    offset = i * STREAM_SIZE;
    // Copy the result back into Z
    cudaMemcpyAsync(
      &Z[offset], &Z_d[offset], sizeof(*Z)*STREAM_SIZE,
      cudaMemcpyDeviceToHost, s.streams[i]);
  }
  offset = (s.n_streams - 1) * STREAM_SIZE;
  cudaMemcpyAsync(
    &Z[offset], &Z_d[offset], sizeof(*Z)*(N-offset),
    cudaMemcpyDeviceToHost, s.streams[s.n_streams-1]);
    
  cuda_check(cudaGetLastError());
  //cuda_check(cudaDeviceSynchronize());
}

#endif

/*
  Test the axpy function to make sure it gives correct results
*/
typedef enum {SUCCESS=0, FAIL} TestResult;

TestResult test_axpy(const int N) {
  // Allocate memory
  float* X = (float*)malloc(sizeof(*X) * N);
  float* Y = (float*)malloc(sizeof(*Y) * N);
  float* Z = (float*)malloc(sizeof(*Z) * N);
  
  // Set up initial values of a, X and Y
  float a = 2.0;
  for (int i = 0; i < N; ++i) {
    X[i] = i;
    Y[i] = 2.*(N-i-1);
  }
  
  // Allocate memory on the GPU for X, Y, Z
  float* X_d; cuda_check(cudaMalloc((void**)&X_d, sizeof(*X_d) * N));
  float* Y_d; cuda_check(cudaMalloc((void**)&Y_d, sizeof(*Y_d) * N));
  float* Z_d; cuda_check(cudaMalloc((void**)&Z_d, sizeof(*Z_d) * N));
  
  // Set up streams
  const int STREAM_SIZE = 256*64; // 64 blocks per stream = 16384 threads
  Streams streams = create_streams(N, STREAM_SIZE);
  
  // Run the kernel a number of times for better statistics
  const int N_TESTS = 1000;
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);
  double millis_total = 0.0;
  
  for (int test = 0; test < N_TESTS; ++test) {
    /// Begin timing
    cuda_check(cudaDeviceSynchronize());
    cudaEventRecord(start);
    
    // Run the kernel
    run_axpy(a, X, X_d, Y, Y_d, Z, Z_d, N, streams, STREAM_SIZE);
    
    /// End timing
    cuda_check(cudaDeviceSynchronize());
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float millisecs = 0;
    cudaEventElapsedTime(&millisecs, start, stop);
    millis_total += millisecs;
  }
  
  // Calculate average execution time
  printf("%10g ms  ...  ", millis_total / N_TESTS);
  cudaEventDestroy(start);
  cudaEventDestroy(stop);
  destroy_streams(streams);
  
  // Check the results are correct
  for (int i = 0; i < N; ++i) {
    if (Z[i] != a*X[i] + Y[i]) return FAIL;
  }
  return SUCCESS;
}


int main(void) {
  int TESTS[] = {1024, 10000, 500000, 5000000, 10000000};
  for (int i = 0; i < sizeof(TESTS)/sizeof(*TESTS); ++i) {
    printf("Testing axpy for N = %-10i...  ", TESTS[i]);
    fflush(stdout);
    if (test_axpy(TESTS[i]) == SUCCESS)
      printf("Passed!\n");
    else {
      printf("Failed!\n");
      return 1;
    }
  }
  printf("\nAll tests passed!\n");
  return 0;
}

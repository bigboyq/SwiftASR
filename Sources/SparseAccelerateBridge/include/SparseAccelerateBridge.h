#ifndef SPARSE_ACCELERATE_BRIDGE_H
#define SPARSE_ACCELERATE_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SwiftASRSparseMatrix SwiftASRSparseMatrix;

SwiftASRSparseMatrix *swiftasr_sparse_matrix_create(
    int count,
    long nonZeroCount,
    const int *rows,
    const int *columns,
    const float *values
);

bool swiftasr_sparse_matrix_multiply(
    const SwiftASRSparseMatrix *matrix,
    const float *input,
    float *output
);

void swiftasr_sparse_matrix_destroy(SwiftASRSparseMatrix *matrix);

#ifdef __cplusplus
}
#endif

#endif

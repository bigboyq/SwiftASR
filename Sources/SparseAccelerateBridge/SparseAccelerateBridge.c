#include "SparseAccelerateBridge.h"

#include <Accelerate/Accelerate.h>
#include <stdlib.h>

struct SwiftASRSparseMatrix {
    int count;
    SparseMatrix_Float matrix;
};

SwiftASRSparseMatrix *swiftasr_sparse_matrix_create(
    int count,
    long nonZeroCount,
    const int *rows,
    const int *columns,
    const float *values
) {
    if (count <= 0 || nonZeroCount <= 0 || rows == NULL || columns == NULL || values == NULL) {
        return NULL;
    }

    SparseAttributes_t attributes = {0};
    attributes.kind = SparseOrdinary;
    SparseMatrix_Float sparse = SparseConvertFromCoordinate(
        count, count, nonZeroCount, 1, attributes, rows, columns, values
    );
    if (sparse.structure.columnStarts == NULL || sparse.structure.rowIndices == NULL || sparse.data == NULL) {
        return NULL;
    }

    SwiftASRSparseMatrix *result = malloc(sizeof(SwiftASRSparseMatrix));
    if (result == NULL) {
        SparseCleanup(sparse);
        return NULL;
    }
    result->count = count;
    result->matrix = sparse;
    return result;
}

bool swiftasr_sparse_matrix_multiply(
    const SwiftASRSparseMatrix *matrix,
    const float *input,
    float *output
) {
    if (matrix == NULL || input == NULL || output == NULL) {
        return false;
    }
    DenseVector_Float x = { .count = matrix->count, .data = (float *)input };
    DenseVector_Float y = { .count = matrix->count, .data = output };
    SparseMultiply(matrix->matrix, x, y);
    return true;
}

void swiftasr_sparse_matrix_destroy(SwiftASRSparseMatrix *matrix) {
    if (matrix == NULL) {
        return;
    }
    SparseCleanup(matrix->matrix);
    free(matrix);
}

import 'dart:typed_data';

/// Helper functions for creating properly shaped tensors
class TensorUtils {
  /// Create a 2D tensor from a 1D Int32List
  static List<List<int>> reshape2DInt32(Int32List data, int rows, int cols) {
    if (data.length != rows * cols) {
      throw ArgumentError('Data length ${data.length} does not match shape [$rows, $cols]');
    }
    
    final result = <List<int>>[];
    for (int i = 0; i < rows; i++) {
      final row = <int>[];
      for (int j = 0; j < cols; j++) {
        row.add(data[i * cols + j]);
      }
      result.add(row);
    }
    return result;
  }
  
  /// Create a 2D tensor from a 1D Float32List
  static List<List<double>> reshape2DFloat32(Float32List data, int rows, int cols) {
    if (data.length != rows * cols) {
      throw ArgumentError('Data length ${data.length} does not match shape [$rows, $cols]');
    }
    
    final result = <List<double>>[];
    for (int i = 0; i < rows; i++) {
      final row = <double>[];
      for (int j = 0; j < cols; j++) {
        row.add(data[i * cols + j]);
      }
      result.add(row);
    }
    return result;
  }
  
  /// Create a 3D tensor from a 1D list
  static List<List<List<T>>> reshape3D<T>(List<T> data, int dim1, int dim2, int dim3) {
    if (data.length != dim1 * dim2 * dim3) {
      throw ArgumentError('Data length ${data.length} does not match shape [$dim1, $dim2, $dim3]');
    }
    
    final result = <List<List<T>>>[];
    for (int i = 0; i < dim1; i++) {
      final dim2List = <List<T>>[];
      for (int j = 0; j < dim2; j++) {
        final dim3List = <T>[];
        for (int k = 0; k < dim3; k++) {
          dim3List.add(data[i * dim2 * dim3 + j * dim3 + k]);
        }
        dim2List.add(dim3List);
      }
      result.add(dim2List);
    }
    return result;
  }
  
  /// Flatten a multi-dimensional list to 1D
  static List<T> flatten<T>(List<dynamic> nested) {
    final result = <T>[];
    
    void flattenRecursive(dynamic item) {
      if (item is List) {
        for (final subItem in item) {
          flattenRecursive(subItem);
        }
      } else if (item is T) {
        result.add(item);
      }
    }
    
    flattenRecursive(nested);
    return result;
  }
  
  /// Print tensor shape for debugging
  static String getTensorShape(dynamic tensor) {
    final shape = <int>[];
    
    dynamic current = tensor;
    while (current is List) {
      shape.add(current.length);
      current = current.isNotEmpty ? current[0] : null;
    }
    
    return '[${shape.join(', ')}]';
  }
}
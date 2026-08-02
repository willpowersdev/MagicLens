import Foundation

// MARK: - Array Helpers

/// Array extension to help with size/memory calculations when working with OpenGL.
extension Array {
  // MARK: - Instance Methods

  /// Returns the memory size/footprint (in bytes) of a given array.
  ///
  /// - Returns: Integer value representing the memory size the array.
  func size() -> Int {
    return count * MemoryLayout.size(ofValue: self[0])
  }
}

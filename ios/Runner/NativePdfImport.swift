import Foundation

/// 工程文件里引用了这个文件，但公开快照没有包含它，也没有任何调用方。
/// 保留一个空类型即可满足 Xcode 的 Sources 编译单元。
final class NativePdfImport {
  private init() {}
}
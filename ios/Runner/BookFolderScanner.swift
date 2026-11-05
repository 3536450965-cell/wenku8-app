import Foundation

/// 公开快照缺少文件夹扫描的原生实现。这里提供一个保守版本：
/// 配置类调用是空操作，扫描返回空结果，暂存/链接直接报错。
/// Dart 侧对 `scanFolderInfo == nil` 和空 `books` 都有处理，因此不会崩。
final class BookFolderScanner {
  init(stateFile: URL, documentsDirectory: URL) throws {
    self.stateFile = stateFile
    self.documentsDirectory = documentsDirectory
  }

  private let stateFile: URL
  private let documentsDirectory: URL

  func info() throws -> Any? {
    return nil
  }

  func select(_ url: URL) throws -> Any? {
    return nil
  }

  func selectApplicationDocuments() throws -> Any? {
    return nil
  }

  func formats() throws -> Any? {
    return nil
  }

  func setFormats(_ extensions: [String]) throws {}

  func setAutomatic(_ value: Bool) throws {}

  func disconnect() throws {}

  func scan() throws -> Any? {
    return ["books": [Any](), "total": 0, "unchanged": 0, "warnings": [String]()]
  }

  func stage(_ token: String, documents: ManagedBookDocuments) throws -> Any? {
    throw BookDocumentFailure(code: "scan_unavailable", message: "当前构建不支持文件夹扫描导入")
  }

  func link(_ token: String, documents: LinkedBookDocuments) throws -> Any? {
    throw BookDocumentFailure(code: "scan_unavailable", message: "当前构建不支持文件夹扫描导入")
  }

  func markImported(_ token: String) throws {}

  func finish() throws {}
}
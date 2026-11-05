import Foundation

/// 公开快照缺少 Kindle / PDF 转换的原生实现。
/// 这两个能力依赖未公开的模块，这里统一给出可读的错误，
/// Dart 侧会捕获并提示「当前构建不支持该格式」。
final class NativeBookConversion {
  init(documents: ManagedBookDocuments, portableRoot: URL) throws {
    self.documents = documents
    self.portableRoot = portableRoot
  }

  private let documents: ManagedBookDocuments
  private let portableRoot: URL

  func extractKindle(_ path: String, output: String) throws -> Int {
    throw BookDocumentFailure(code: "format_unavailable", message: "当前构建不支持 MOBI / AZW3 转换，请先转换为 EPUB")
  }

  func extractPdf(_ path: String, output: String, name: String) throws {
    throw BookDocumentFailure(code: "format_unavailable", message: "当前构建不支持 PDF 导入，请先转换为 EPUB")
  }
}

/// 原件在公开快照里缺失，这里按 `lib/book_import_limits.dart` 的口径重建：
/// 同名的 Dart 侧 `localBookByteLimit` / `supportsBookImport` 保持同一套限额。
enum BookImportFormatPolicy {
  static let extensions: Set<String> = [
    "txt", "epub", "mobi", "azw", "azw3", "prc", "fb2", "pdf",
    "docx", "doc", "rtf", "html", "htm", "xhtml", "md", "markdown", "zip",
  ]

  private static func baseLimit(_ ext: String) -> Int64 {
    switch ext.lowercased() {
    case "zip", "epub", "pdf", "docx": return 512 * 1024 * 1024
    case "mobi", "azw", "azw3", "prc": return 256 * 1024 * 1024
    case "html", "htm", "xhtml", "md", "markdown": return 32 * 1024 * 1024
    default: return 128 * 1024 * 1024
    }
  }

  static func byteLimit<T: BinaryInteger>(_ ext: String) -> T {
    return T(baseLimit(ext))
  }
}
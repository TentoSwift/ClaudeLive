import Foundation

/// 保存済みのデーモン URL に紛れ込んだインターフェースのスコープ ID
/// （"192.168.0.1%en0" の "%en0" 部分）を落とす。NWEndpoint.Host の
/// 文字列化で IPv4 でも混入することがあり、そのままでは URLSession が
/// 解決できない。過去に壊れた値が保存されている可能性があるので、
/// 保存時だけでなく読み込み時にも通す
func sanitizeDaemonURL(_ url: String) -> String {
    guard let percent = url.range(of: "%"),
          let colon = url[percent.upperBound...].firstIndex(of: ":") else { return url }
    return String(url[..<percent.lowerBound]) + String(url[colon...])
}

import Foundation
import ClaudeWeekCore

/// Отпечаток файла конфига: inode + размер + время правки. Сравнение
/// отпечатков переживает атомарную запись, при которой файл подменяется
/// целиком и наблюдатель по дескриптору теряет цель.
struct ConfigStamp: Equatable {
    let inode: UInt64
    let size: UInt64
    let mtime: Date

    static func current(url: URL = ConfigStore.fileURL) -> ConfigStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return ConfigStamp(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            mtime: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }
}

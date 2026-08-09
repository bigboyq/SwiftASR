import Testing
import Foundation
@testable import SwiftASR

@Suite("SettingsStore 缓存命中与更新一致性测试")
@MainActor
struct Phase9SettingsStoreCacheTests {
    
    @Test func cacheHitAfterFirstLoad() {
        let store = SettingsStore.createTestInstance()
        store.resetCacheForTesting()
        let fm = FileManager.default
        let settingsURL = store.settingsFileURL
        
        // 预设一个干净的环境
        let originalKeys = [APIKeyConfig(label: "test-label", keyValue: "secret-key", priority: 1)]
        store.setApiKeys(originalKeys)
        
        // 第一次载入，确保 cachedBlob 被填充
        let firstFetch = store.apiKeys()
        #expect(firstFetch.first?.label == "test-label")
        
        // 删除磁盘上的 settings.json
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: settingsURL)
        }
        
        // 第二次获取，如果去读盘必然因文件缺失而返回空；如果命中缓存，应当仍能读到
        let secondFetch = store.apiKeys()
        #expect(secondFetch.first?.label == "test-label", "应当命中内存缓存")
    }
    
    @Test func writeUpdatesCache() {
        let store = SettingsStore.createTestInstance()
        store.resetCacheForTesting()
        let fm = FileManager.default
        let settingsURL = store.settingsFileURL
        
        // 写入新值
        let newKeys = [APIKeyConfig(label: "new-label-cached", keyValue: "new-key", priority: 2)]
        store.setApiKeys(newKeys)
        
        // 验证写入完后，立刻删除文件，读取依旧从缓存中更新了
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: settingsURL)
        }
        
        let fetched = store.apiKeys()
        #expect(fetched.first?.label == "new-label-cached", "写入应当同步更新内存缓存")
    }
}

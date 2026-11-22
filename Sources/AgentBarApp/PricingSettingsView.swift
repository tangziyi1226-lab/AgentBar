import AgentBarCore
import SwiftUI

struct PricingSettingsView: View {
    @Bindable var model: AppModel
    @State private var custom = false
    @State private var search = ""
    @State private var editing = false
    @State private var detail: String?

    private var models: [String] {
        Set(model.sessions.compactMap { $0.model?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        let _ = model.pricingRevision
        let names = custom ? model.customPriceRules.map(\.modelPrefix).sorted() : models
        let visible = names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 12) {
            catalogHeader
            Divider()
            HStack {
                Picker("查看价格", selection: $custom) {
                    Text("会话模型").tag(false)
                    Text("自定义规则").tag(true)
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(custom ? "搜索规则" : "搜索模型或渠道", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }.padding(5).frame(width: 153).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                if custom {
                    Button { startEditing() } label: { Label("添加规则", systemImage: "plus") }
                }
            }
            HStack {
                Text(custom ? "自定义规则优先于目录价" : "近期会话使用的模型")
                Spacer()
                Text("美元 / 百万 Token").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                priceLine(name: custom ? "匹配前缀" : "模型", rule: nil)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.vertical, 7).background(.quaternary.opacity(0.65))
                Divider()
                if visible.isEmpty {
                    VStack(spacing: 8) {
                        Text(!search.isEmpty ? "没有匹配结果" : custom ? "尚未设置自定义价格" : "暂无会话模型").font(.headline)
                        Text(!search.isEmpty ? "试试更短的名称。" : custom ? "当前使用目录价格。需要不同费率时，点「添加规则」。" : "有会话使用模型后，这里会显示对应价格。")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible, id: \.self) { name in
                                let match = custom ? model.customPriceRules.first { $0.modelPrefix == name } : PricingCatalog.rule(for: name)
                                let rule = match ?? PricingCatalog.fallbackDefaultRule
                                Button { detail = name } label: {
                                    priceLine(name: name, rule: rule).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("\(name) · 查看匹配详情")
                                .popover(isPresented: Binding(get: { detail == name }, set: { if !$0 { detail = nil } })) {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Text(name).font(.headline).textSelection(.enabled)
                                        Text(match == nil ? "未匹配模型，使用默认估价" : "匹配规则：\(rule.modelPrefix)")
                                        Text("上下文窗口：\(rule.defaultContextWindow.formatted()) tokens")
                                        if let tier = rule.over272k {
                                            Text("Codex 单次输入超过 272,000（含缓存）时，每百万 Token：输入 \(tier.input.formatted())、输出 \(tier.output.formatted())、缓存读 \(tier.cacheRead.formatted())、缓存写 \(tier.cacheWrite.formatted()) 美元。无单次明细按表中基础价估算。")
                                        }
                                        if custom {
                                            HStack {
                                                Button("编辑") { detail = nil; startEditing(rule) }
                                                Button("删除规则", role: .destructive) {
                                                    detail = nil
                                                    model.customPriceRules.removeAll { $0.modelPrefix == name }
                                                }
                                            }
                                        }
                                    }.font(.callout).padding(14).frame(maxWidth: 350, alignment: .leading)
                                }
                                Divider()
                            }
                        }
                    }
                }
            }.background(.background).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary) }
            HStack {
                Text(search.isEmpty ? "共 \(names.count) 项" : "找到 \(visible.count) / \(names.count) 项")
                Spacer()
                Text(custom ? "点选规则可编辑或删除" : "点选模型查看匹配规则和上下文")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(14)
        .onChange(of: custom) { search = ""; detail = nil }
        .sheet(isPresented: $editing) { ruleEditor }
    }

    private var catalogHeader: some View {
        let status = model.pricingSyncStatus
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("价格目录").font(.title3.weight(.semibold))
                Spacer()
                Toggle("自动同步", isOn: $model.autoSyncPricingEnabled).toggleStyle(.switch).controlSize(.small)
                Button { Task { await model.syncModelPricingNow() } } label: {
                    Label(model.isSyncingPricing ? "同步中…" : "同步", systemImage: "arrow.clockwise")
                }.disabled(model.isSyncingPricing)
            }
            let updated = status.lastSyncedAt.map { " · \(FormattingHelpers.relativeDuration(since: $0))更新" } ?? ""
            Text("\(status.source) · \(status.activeModelCount) 个模型\(updated)").font(.callout).foregroundStyle(.secondary)
            if let error = status.errorMessage, !error.isEmpty {
                Label("同步失败，使用本地价格", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).help(error)
            }
        }
    }

    private func priceLine(name: String, rule: ModelPriceRule?) -> some View {
        let titles = ["输入", "输出", "缓存读", "缓存写"]
        let prices = rule.map { [$0.inputPerMillionUSD, $0.outputPerMillionUSD, $0.cacheReadPerMillionUSD, $0.cacheWritePerMillionUSD] }
        return HStack(spacing: 6) {
            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(titles.indices, id: \.self) { index in
                Text(prices.map { $0[index].formatted(.number.precision(.significantDigits(1...6))) } ?? titles[index])
                    .monospacedDigit().lineLimit(1).frame(width: 62, alignment: .trailing)
            }
        }.padding(.horizontal, 10)
    }

    private func startEditing(_ rule: ModelPriceRule? = nil) {
        model.newPricePrefixDraft = rule?.modelPrefix ?? ""
        model.newPriceInputDraft = rule.map { String($0.inputPerMillionUSD) } ?? "0"
        model.newPriceOutputDraft = rule.map { String($0.outputPerMillionUSD) } ?? "0"
        model.newPriceCacheReadDraft = rule.map { String($0.cacheReadPerMillionUSD) } ?? "0"
        model.newPriceCacheWriteDraft = rule.map { String($0.cacheWritePerMillionUSD) } ?? "0"
        editing = true
    }

    private var ruleEditor: some View {
        let prefix = model.newPricePrefixDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = model.customPriceRules.contains { $0.modelPrefix.caseInsensitiveCompare(prefix) == .orderedSame }
        let validPrices = [model.newPriceInputDraft, model.newPriceOutputDraft, model.newPriceCacheReadDraft, model.newPriceCacheWriteDraft]
            .allSatisfy { Double($0).map { $0.isFinite && $0 >= 0 } == true }
        return VStack(alignment: .leading, spacing: 12) {
            Text("自定义价格").font(.title3.weight(.semibold))
            Text("按模型或网关前缀覆盖目录价。免费渠道可将四项都设为 0。")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("匹配前缀"); TextField("如 internal/", text: $model.newPricePrefixDraft) }
                GridRow { Text("输入"); TextField("0", text: $model.newPriceInputDraft) }
                GridRow { Text("输出"); TextField("0", text: $model.newPriceOutputDraft) }
                GridRow { Text("缓存读"); TextField("0", text: $model.newPriceCacheReadDraft) }
                GridRow { Text("缓存写"); TextField("0", text: $model.newPriceCacheWriteDraft) }
            }.textFieldStyle(.roundedBorder)
            Text(validPrices ? "单位：美元 / 百万 Token" : "请输入非负数，小数点使用 .")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { editing = false }.keyboardShortcut(.cancelAction)
                Button(existing ? "覆盖同名规则" : "添加规则") {
                    model.addCustomPriceRuleFromDraft(); search = ""; editing = false
                }.keyboardShortcut(.defaultAction).disabled(prefix.isEmpty || !validPrices)
            }
        }.padding(20).frame(width: 360)
    }
}

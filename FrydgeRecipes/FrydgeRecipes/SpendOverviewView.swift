//
//  SpendOverviewView.swift
//  FrydgeRecipes
//
//  Profile → Spending: this-month and all-time spend plus a history of scanned
//  receipts, backed by ReceiptStore (CloudKit private DB).
//

import SwiftUI

struct SpendOverviewView: View {
    @ObservedObject private var store = ReceiptStore.shared
    @EnvironmentObject private var frydgeManager: FrydgeManager
    @State private var showReceiptScan = false

    private var currencyCode: String { store.receipts.first?.currencyCode ?? "NZD" }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    spendCard(title: "This month", value: store.thisMonthTotal)
                    spendCard(title: "All time", value: store.allTimeTotal)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if store.receipts.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(store.isLoading ? "Loading…" : "No receipts yet")
                            .font(.headline)
                        Text("Scan a receipt after a shop to track spend and top up your fridge.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            showReceiptScan = true
                        } label: {
                            Label("Scan a Receipt", systemImage: "doc.text.viewfinder")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Receipts") {
                    ForEach(store.receipts) { receipt in
                        NavigationLink {
                            ReceiptDetailView(receipt: receipt)
                        } label: {
                            receiptRow(receipt)
                        }
                    }
                    .onDelete { indexSet in
                        let toDelete = indexSet.map { store.receipts[$0] }
                        Task { for r in toDelete { await store.delete(r) } }
                    }
                }
            }
        }
        .navigationTitle("Spending")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(isPresented: $showReceiptScan) {
            ReceiptScanView()
                .environmentObject(frydgeManager)
        }
    }

    private func spendCard(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(currencyString(value))
                .font(.title2.weight(.bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func receiptRow(_ receipt: Receipt) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.storeName ?? "Shop")
                    .font(.body.weight(.medium))
                Text("\(receipt.date.formatted(date: .abbreviated, time: .omitted)) · \(receipt.itemCount) item\(receipt.itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(receipt.total > 0 ? receipt.totalText : "—")
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    private func currencyString(_ value: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currencyCode
        return nf.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}

private struct ReceiptDetailView: View {
    let receipt: Receipt

    var body: some View {
        List {
            Section {
                LabeledContent("Store", value: receipt.storeName ?? "Unknown")
                LabeledContent("Date", value: receipt.date.formatted(date: .long, time: .shortened))
                LabeledContent("Total", value: receipt.total > 0 ? receipt.totalText : "—")
            }
            if !receipt.items.isEmpty {
                Section("Items (\(receipt.items.count))") {
                    ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
            }
        }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
    }
}

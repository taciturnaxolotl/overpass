import SwiftUI
import StoreKit

struct PaywallView: View {
    private let store = StoreManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)

                VStack(spacing: 6) {
                    Text("Overpass")
                        .font(.largeTitle.bold())

                    Text("Find the cheapest gas near you.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                FeatureRow(icon: "dollarsign.circle.fill", color: .green,
                           title: "Real-time prices", subtitle: "Always up-to-date gas prices nearby")
                FeatureRow(icon: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill", color: .blue,
                           title: "Route pre-caching", subtitle: "Prefetch stations along any route")
                FeatureRow(icon: "mic.circle.fill", color: .purple,
                           title: "Siri shortcuts", subtitle: "Find gas hands-free")
                FeatureRow(icon: "arrow.clockwise.circle.fill", color: .orange,
                           title: "Background refresh", subtitle: "Prices stay fresh automatically")
            }
            .padding(.horizontal)

            Spacer()

            if store.isInTrial {
                let days = store.daysRemainingInTrial
                Text("\(days) day\(days == 1 ? "" : "s") left in your free trial")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 16)
            }

            VStack(spacing: 12) {
                Button {
                    Task { try? await store.purchase() }
                } label: {
                    Group {
                        if store.isPurchasing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Get Overpass — \(store.product?.displayPrice ?? "$2.99")")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(store.isPurchasing)

                Button("Restore Purchase") {
                    Task { await store.restore() }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Text("One-time purchase · No subscription")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
                .padding(.bottom, 32)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

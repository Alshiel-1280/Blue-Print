import Combine
import Foundation

@MainActor
final class AppSessionStore: ObservableObject {
  @Published var selectedDestination: AppDestination? = .home
  @Published var selectedFiscalYear: Int?
  @Published var isUtilityAreaVisible = false
}

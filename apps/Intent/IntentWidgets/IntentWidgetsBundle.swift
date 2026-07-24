import SwiftUI
import WidgetKit

@main
struct IntentWidgetsBundle: WidgetBundle {
    var body: some Widget {
        IntentionalityTodayWidget()
        IntentionalityTrendWidget()
        IntentTrackedHoursWidget()
    }
}

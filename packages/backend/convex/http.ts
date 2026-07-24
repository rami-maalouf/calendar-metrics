import { httpRouter } from "convex/server";

import { authComponent, createAuth } from "./auth";
import {
  acknowledgeFocusComplete,
  acknowledgeFocusStart,
  acknowledgeReviewPresented,
  ackScreenNotification,
  bootstrap,
  deviceDashboard,
  deviceDailyReport,
  deviceIntentionality,
  deviceMetrics,
  deviceScreenSummary,
  ingestScreenDay,
  recordHourlyIntentionality,
  health,
  pullDevice,
  pollDevice,
  submitReview,
  togglWebhook,
} from "./intentHttp";

const http = httpRouter();

authComponent.registerRoutes(http, createAuth);

http.route({
  path: "/intent/bootstrap",
  method: "POST",
  handler: bootstrap,
});

http.route({
  path: "/intent/device/poll",
  method: "POST",
  handler: pollDevice,
});

http.route({
  path: "/intent/device/metrics",
  method: "POST",
  handler: deviceMetrics,
});

http.route({
  path: "/intent/device/dashboard",
  method: "POST",
  handler: deviceDashboard,
});

http.route({
  path: "/intent/device/daily-report",
  method: "POST",
  handler: deviceDailyReport,
});

http.route({
  path: "/intent/device/intentionality",
  method: "POST",
  handler: deviceIntentionality,
});

http.route({
  path: "/intent/device/intentionality/record",
  method: "POST",
  handler: recordHourlyIntentionality,
});

http.route({
  path: "/intent/device/screen/ingest",
  method: "POST",
  handler: ingestScreenDay,
});

http.route({
  path: "/intent/device/screen/summary",
  method: "POST",
  handler: deviceScreenSummary,
});

http.route({
  path: "/intent/device/screen/ack-notification",
  method: "POST",
  handler: ackScreenNotification,
});

http.route({
  path: "/intent/device/pull",
  method: "POST",
  handler: pullDevice,
});

http.route({
  path: "/intent/device/focus/start",
  method: "POST",
  handler: acknowledgeFocusStart,
});

http.route({
  path: "/intent/device/focus/complete",
  method: "POST",
  handler: acknowledgeFocusComplete,
});

http.route({
  path: "/intent/device/review/presented",
  method: "POST",
  handler: acknowledgeReviewPresented,
});

http.route({
  path: "/intent/device/review/submit",
  method: "POST",
  handler: submitReview,
});

http.route({
  path: "/intent/webhooks/toggl",
  method: "POST",
  handler: togglWebhook,
});

http.route({
  path: "/intent/health",
  method: "GET",
  handler: health,
});

export default http;

import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  events: defineTable({
    googleEventId: v.string(),
    calendarId: v.string(),
    title: v.string(),
    description: v.optional(v.string()),
    isAllDay: v.optional(v.boolean()),
    startTime: v.number(),
    endTime: v.number(),
  }).index("by_googleEventId", ["googleEventId"]),

  metricValues: defineTable({
    eventId: v.id("events"),
    key: v.string(),
    value: v.union(v.number(), v.boolean(), v.string()),
  })
    .index("by_eventId", ["eventId"])
    .index("by_key", ["key"]),

  metricObservations: defineTable({
    subjectType: v.string(),
    subjectId: v.string(),
    eventId: v.optional(v.id("events")),
    sessionId: v.optional(v.id("intentSessions")),
    calendarId: v.optional(v.string()),
    workspaceId: v.optional(v.number()),
    key: v.string(),
    valueType: v.string(),
    numberValue: v.optional(v.number()),
    booleanValue: v.optional(v.boolean()),
    stringValue: v.optional(v.string()),
    subjectTitle: v.string(),
    observedAt: v.number(),
    source: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_subjectType_subjectId", ["subjectType", "subjectId"])
    .index("by_calendarId_observedAt", ["calendarId", "observedAt"])
    .index("by_subjectType_observedAt", ["subjectType", "observedAt"])
    .index("by_subjectType_key_observedAt", [
      "subjectType",
      "key",
      "observedAt",
    ])
    .index("by_key_observedAt", ["key", "observedAt"]),

  userSecrets: defineTable({
    userId: v.string(), // Links to Better Auth user ID
    key: v.string(), // e.g. "google_refresh_token"
    value: v.string(),
  }).index("by_userId_key", ["userId", "key"]),

  userSettings: defineTable({
    userId: v.string(), // Links to Better Auth user ID
    selectedCalendarId: v.optional(v.string()), // Google Calendar ID to track
    selectedCalendarName: v.optional(v.string()), // Human-readable name
    onboardingCompleted: v.optional(v.boolean()), // Track onboarding status
  }).index("by_userId", ["userId"]),

  intentDevices: defineTable({
    deviceId: v.string(),
    deviceSecret: v.string(),
    name: v.string(),
    platform: v.string(),
    bundleId: v.optional(v.string()),
    autoStartFocus: v.boolean(),
    autoCompleteFocus: v.boolean(),
    autoShowReview: v.boolean(),
    startShortcutName: v.optional(v.string()),
    completeShortcutName: v.optional(v.string()),
    lastSeenAt: v.optional(v.number()),
    isDefault: v.boolean(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_deviceId", ["deviceId"])
    .index("by_isDefault", ["isDefault"]),

  intentIntegrationState: defineTable({
    slug: v.string(),
    defaultDeviceId: v.optional(v.string()),
    togglWorkspaceId: v.optional(v.number()),
    togglWebhookSubscriptionId: v.optional(v.number()),
    togglWebhookSecret: v.optional(v.string()),
    togglWebhookDescription: v.optional(v.string()),
    togglWebhookUrl: v.optional(v.string()),
    togglWebhookValidatedAt: v.optional(v.number()),
    lastWebhookAt: v.optional(v.number()),
    lastWebhookEntity: v.optional(v.string()),
    lastWebhookAction: v.optional(v.string()),
    lastWebhookTimeEntryId: v.optional(v.string()),
    lastWebhookError: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_slug", ["slug"]),

  intentSessions: defineTable({
    source: v.string(),
    sourceTimeEntryId: v.string(),
    workspaceId: v.number(),
    togglUserId: v.optional(v.number()),
    togglProjectId: v.optional(v.number()),
    projectName: v.optional(v.string()),
    togglTaskId: v.optional(v.number()),
    description: v.optional(v.string()),
    tagJson: v.optional(v.string()),
    billable: v.optional(v.boolean()),
    startTimeMs: v.number(),
    stopTimeMs: v.optional(v.number()),
    durationMs: v.optional(v.number()),
    status: v.string(),
    focusStatus: v.string(),
    focusStartedAt: v.optional(v.number()),
    focusCompletedAt: v.optional(v.number()),
    focusDeviceId: v.optional(v.string()),
    reviewStatus: v.string(),
    reviewPresentedAt: v.optional(v.number()),
    reviewPresentedDeviceId: v.optional(v.string()),
    reviewSubmittedAt: v.optional(v.number()),
    lastWebhookAction: v.string(),
    sourceUpdatedAt: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_sourceTimeEntryId", ["sourceTimeEntryId"])
    .index("by_status_startTimeMs", ["status", "startTimeMs"])
    .index("by_focusStatus_updatedAt", ["focusStatus", "updatedAt"])
    .index("by_reviewStatus_updatedAt", ["reviewStatus", "updatedAt"]),

  intentSessionReviews: defineTable({
    sessionId: v.id("intentSessions"),
    taskCategory: v.optional(v.string()),
    numericMetricsJson: v.optional(v.string()),
    countMetricsJson: v.optional(v.string()),
    booleanMetricsJson: v.optional(v.string()),
    whatWentWell: v.optional(v.string()),
    whatDidntGoWell: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_sessionId", ["sessionId"]),

  intentWebhookEvents: defineTable({
    dedupeKey: v.string(),
    entity: v.string(),
    action: v.string(),
    entityId: v.string(),
    workspaceId: v.optional(v.number()),
    happenedAt: v.optional(v.number()),
    receivedAt: v.number(),
    payloadJson: v.string(),
  })
    .index("by_dedupeKey", ["dedupeKey"])
    .index("by_receivedAt", ["receivedAt"]),

  // daily phone screen rollup from biome App.InFocus (mac collector)
  intentScreenDays: defineTable({
    ownerDeviceId: v.string(),
    dayKey: v.string(),
    source: v.string(),
    sourceDeviceId: v.string(),
    platform: v.string(),
    totalSeconds: v.number(),
    eventCount: v.number(),
    cleanedEventCount: v.number(),
    topAppsJson: v.string(),
    hourlyTotalsJson: v.string(),
    notificationBody: v.string(),
    notificationDeliveredAt: v.optional(v.number()),
    timeZoneOffsetMinutes: v.number(),
    collectedAt: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_owner_day_sourceDevice", [
      "ownerDeviceId",
      "dayKey",
      "sourceDeviceId",
    ])
    .index("by_owner_dayKey", ["ownerDeviceId", "dayKey"])
    .index("by_owner_collectedAt", ["ownerDeviceId", "collectedAt"]),

  // per-app daily rollup
  intentScreenAppDays: defineTable({
    ownerDeviceId: v.string(),
    dayKey: v.string(),
    sourceDeviceId: v.string(),
    bundleId: v.string(),
    title: v.string(),
    seconds: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_owner_day_sourceDevice", [
      "ownerDeviceId",
      "dayKey",
      "sourceDeviceId",
    ])
    .index("by_owner_day_bundle", ["ownerDeviceId", "dayKey", "bundleId"]),

  // per-hour rollup (local day hour 0-23)
  intentScreenHours: defineTable({
    ownerDeviceId: v.string(),
    dayKey: v.string(),
    sourceDeviceId: v.string(),
    hourStartMs: v.number(),
    hourOfDay: v.number(),
    totalSeconds: v.number(),
    topAppsJson: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_owner_day_sourceDevice", [
      "ownerDeviceId",
      "dayKey",
      "sourceDeviceId",
    ])
    .index("by_owner_hourStartMs", ["ownerDeviceId", "hourStartMs"]),
});

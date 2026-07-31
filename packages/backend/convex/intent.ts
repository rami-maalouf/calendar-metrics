import { v } from "convex/values";

import type { Doc, Id } from "./_generated/dataModel";
import {
  mutation,
  query,
  internalMutation,
  internalQuery,
} from "./_generated/server";
import {
  replaceMetricObservationsForEvent,
  replaceMetricObservationsForIntentSession,
  upsertHourlyIntentionalityObservation,
} from "./metricObservations";

const DEFAULT_INTEGRATION_SLUG = "default";
const DEFAULT_METRICS_WINDOW_DAYS = 21;
const MIN_METRICS_WINDOW_DAYS = 7;
const MAX_METRICS_WINDOW_DAYS = 90;
const DEVICE_HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const INTENTIONALITY_SUBJECT_TYPE = "intentionalityHour";
const INTENTIONALITY_KEY = "intentionality";
const DEFAULT_INTENTIONALITY_WINDOW_DAYS = 30;
const MIN_INTENTIONALITY_WINDOW_DAYS = 1;
const MAX_INTENTIONALITY_WINDOW_DAYS = 180;
const convexNumber = v.union(v.number(), v.int64());
const INTENT_COUNT_METRIC_KEYS = new Set(["distractions"]);
const INTENT_SIGNAL_ORDER = [
  "focus",
  "discipline",
  "engagement",
  "mindfulness",
  "energy",
  "intentionality",
  "adherence",
  "purpose",
  "courage",
  "authenticity",
  "communication",
  "uniqueness",
] as const;
const INTENT_METRIC_TITLES: Record<string, string> = {
  mindfulness: "Mindfulness",
  discipline: "Discipline",
  engagement: "Engagement",
  focus: "Focus",
  courage: "Courage",
  authenticity: "Authenticity",
  purpose: "Purpose",
  energy: "Energy",
  communication: "Communication",
  uniqueness: "Uniqueness",
  adherence: "Adherence",
  intentionality: "Intentionality",
  distractions: "Distractions",
  taskCategory: "Task Category",
};

type DeviceSettings = {
  autoStartFocus?: boolean;
  autoCompleteFocus?: boolean;
  autoShowReview?: boolean;
  startShortcutName?: string;
  completeShortcutName?: string;
  bundleId?: string;
};

type ConvexNumberArg = number | bigint;

type TogglTimeEntry = {
  id: number;
  workspace_id: number;
  user_id?: number;
  project_id?: number;
  task_id?: number;
  description?: string;
  tags?: string[];
  billable?: boolean;
  start: string;
  stop?: string;
  duration?: number;
  at?: string;
};

function now() {
  return Date.now();
}

function generateToken(prefix: string) {
  return `${prefix}_${crypto.randomUUID().replace(/-/g, "")}`;
}

function parseTags(tagJson?: string) {
  if (!tagJson) {
    return [] as string[];
  }

  try {
    const parsed = JSON.parse(tagJson);
    return Array.isArray(parsed)
      ? parsed.filter((value): value is string => typeof value === "string")
      : [];
  } catch {
    return [];
  }
}

function toSessionSummary(session: Doc<"intentSessions">) {
  return {
    id: session._id,
    source: session.source,
    sourceTimeEntryId: session.sourceTimeEntryId,
    workspaceId: session.workspaceId,
    togglUserId: session.togglUserId ?? null,
    togglProjectId: session.togglProjectId ?? null,
    projectName: session.projectName ?? null,
    togglTaskId: session.togglTaskId ?? null,
    description: session.description ?? "",
    tags: parseTags(session.tagJson),
    billable: session.billable ?? null,
    startTimeMs: session.startTimeMs,
    stopTimeMs: session.stopTimeMs ?? null,
    durationMs: session.durationMs ?? null,
    status: session.status,
    focusStatus: session.focusStatus,
    reviewStatus: session.reviewStatus,
    sourceUpdatedAt: session.sourceUpdatedAt,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
  };
}

function parseRecord<T>(
  rawValue: string | undefined,
  predicate: (value: unknown) => value is T,
) {
  if (!rawValue) {
    return {} as Record<string, T>;
  }

  try {
    const parsed = JSON.parse(rawValue);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return {} as Record<string, T>;
    }

    return Object.entries(parsed).reduce(
      (result, [key, value]) => {
        if (predicate(value)) {
          result[key] = value;
        }
        return result;
      },
      {} as Record<string, T>,
    );
  } catch {
    return {} as Record<string, T>;
  }
}

function normalizedReviewPayload(review: Doc<"intentSessionReviews">) {
  const numericMetrics = parseRecord(
    review.numericMetricsJson,
    (value): value is number => typeof value === "number" && Number.isFinite(value),
  );
  const countMetrics = parseRecord(
    review.countMetricsJson,
    (value): value is number => typeof value === "number" && Number.isFinite(value),
  );
  const booleanMetrics = parseRecord(
    review.booleanMetricsJson,
    (value): value is boolean => typeof value === "boolean",
  );

  return {
    numericMetrics,
    countMetrics,
    booleanMetrics,
    taskCategory: review.taskCategory ?? "",
    whatWentWell: review.whatWentWell ?? "",
    whatDidntGoWell: review.whatDidntGoWell ?? "",
  };
}

function toReviewSummary(review: Doc<"intentSessionReviews"> | null) {
  if (!review) {
    return null;
  }

  return normalizedReviewPayload(review);
}

function isPendingReviewStatus(status: string) {
  return status === "pending" || status === "presented";
}

function clampMetricsWindowDays(value?: number) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_METRICS_WINDOW_DAYS;
  }

  return Math.min(MAX_METRICS_WINDOW_DAYS, Math.max(MIN_METRICS_WINDOW_DAYS, Math.round(value)));
}

function roundMetric(value: number, digits = 1) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function averageOf(values: number[]) {
  if (values.length === 0) {
    return 0;
  }

  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function sessionDurationMs(session: Doc<"intentSessions">) {
  if (typeof session.durationMs === "number" && Number.isFinite(session.durationMs)) {
    return session.durationMs;
  }

  if (typeof session.stopTimeMs === "number") {
    return Math.max(0, session.stopTimeMs - session.startTimeMs);
  }

  return 0;
}

function sessionOverlapDurationMs(
  session: Doc<"intentSessions">,
  windowStartTimeMs: number,
  windowEndTimeMs: number,
  fallbackEndTimeMs: number,
) {
  const sessionEndTimeMs =
    typeof session.stopTimeMs === "number" ? session.stopTimeMs : fallbackEndTimeMs;
  const clippedStartTimeMs = Math.max(windowStartTimeMs, session.startTimeMs);
  const clippedEndTimeMs = Math.min(windowEndTimeMs, sessionEndTimeMs);
  return Math.max(0, clippedEndTimeMs - clippedStartTimeMs);
}

function metricTitle(key: string) {
  if (INTENT_METRIC_TITLES[key]) {
    return INTENT_METRIC_TITLES[key];
  }

  return key
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (character) => character.toUpperCase());
}

function metricSortIndex(key: string) {
  const index = INTENT_SIGNAL_ORDER.indexOf(key as (typeof INTENT_SIGNAL_ORDER)[number]);
  return index >= 0 ? index : INTENT_SIGNAL_ORDER.length + 1;
}

function observedDayKey(timestamp: number) {
  const date = new Date(timestamp);
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function computeDayStreak(dayKeys: string[]) {
  const sortedKeys = [...new Set(dayKeys)].sort((left, right) =>
    left < right ? 1 : left > right ? -1 : 0,
  );

  if (sortedKeys.length === 0) {
    return 0;
  }

  let streak = 1;
  let previousDate = new Date(`${sortedKeys[0]}T00:00:00.000Z`);

  for (const key of sortedKeys.slice(1)) {
    const currentDate = new Date(`${key}T00:00:00.000Z`);
    const differenceDays = Math.round(
      (previousDate.getTime() - currentDate.getTime()) / (24 * 60 * 60 * 1000),
    );

    if (differenceDays !== 1) {
      break;
    }

    streak += 1;
    previousDate = currentDate;
  }

  return streak;
}

function startOfUTCDay(timestamp: number) {
  const date = new Date(timestamp);
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
}

function toFiniteNumber(value?: ConvexNumberArg) {
  if (typeof value === "bigint") {
    return Number(value);
  }
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return undefined;
  }
  return value;
}

function clampIntentionalityWindowDays(value?: ConvexNumberArg) {
  const numberValue = toFiniteNumber(value);
  if (numberValue === undefined) {
    return DEFAULT_INTENTIONALITY_WINDOW_DAYS;
  }

  return Math.min(
    MAX_INTENTIONALITY_WINDOW_DAYS,
    Math.max(MIN_INTENTIONALITY_WINDOW_DAYS, Math.round(numberValue)),
  );
}

function clampIntentionalityScore(value: ConvexNumberArg) {
  const numberValue = toFiniteNumber(value);
  if (numberValue === undefined) {
    throw new Error("Intentionality score must be a finite number.");
  }

  return roundMetric(Math.min(10, Math.max(0, numberValue)));
}

function normalizedObservedAt(value?: ConvexNumberArg) {
  const numberValue = toFiniteNumber(value);
  if (numberValue === undefined) {
    return now();
  }

  return Math.max(0, Math.round(numberValue));
}

function hourStart(timestamp: number) {
  return Math.floor(timestamp / HOUR_MS) * HOUR_MS;
}

function normalizedTimeZoneOffsetMinutes(value?: ConvexNumberArg) {
  const numberValue = toFiniteNumber(value);
  if (numberValue === undefined) {
    return 0;
  }

  return Math.min(14 * 60, Math.max(-14 * 60, Math.round(numberValue)));
}

function localDateParts(timestamp: number, timeZoneOffsetMinutes: number) {
  const date = new Date(timestamp + timeZoneOffsetMinutes * 60 * 1000);
  return {
    year: date.getUTCFullYear(),
    month: date.getUTCMonth() + 1,
    day: date.getUTCDate(),
    hour: date.getUTCHours(),
  };
}

function localDayKey(timestamp: number, timeZoneOffsetMinutes: number) {
  const parts = localDateParts(timestamp, timeZoneOffsetMinutes);
  return [
    parts.year,
    String(parts.month).padStart(2, "0"),
    String(parts.day).padStart(2, "0"),
  ].join("-");
}

function localDayStartMs(timestamp: number, timeZoneOffsetMinutes: number) {
  const parts = localDateParts(timestamp, timeZoneOffsetMinutes);
  return (
    Date.UTC(parts.year, parts.month - 1, parts.day) -
    timeZoneOffsetMinutes * 60 * 1000
  );
}

function hourLabel(hour: number) {
  if (hour === 0) {
    return "12 AM";
  }
  if (hour < 12) {
    return `${hour} AM`;
  }
  if (hour === 12) {
    return "12 PM";
  }
  return `${hour - 12} PM`;
}

function computeLocalDayStreak(
  dayKeys: string[],
  timestamp: number,
  timeZoneOffsetMinutes: number,
) {
  const daySet = new Set(dayKeys);
  let cursor = localDayStartMs(timestamp, timeZoneOffsetMinutes);
  let streak = 0;

  while (daySet.has(localDayKey(cursor, timeZoneOffsetMinutes))) {
    streak += 1;
    cursor -= DAY_MS;
  }

  return streak;
}

function intentionalityObservationToEntry(
  observation: Doc<"metricObservations">,
  timeZoneOffsetMinutes: number,
) {
  const parts = localDateParts(observation.observedAt, timeZoneOffsetMinutes);
  return {
    id: observation._id,
    hourStartMs: observation.observedAt,
    score: observation.numberValue ?? 0,
    dayKey: localDayKey(observation.observedAt, timeZoneOffsetMinutes),
    hour: parts.hour,
    hourLabel: hourLabel(parts.hour),
    source: observation.source,
    updatedAt: observation.updatedAt,
  };
}

type IntentionalityEntry = ReturnType<typeof intentionalityObservationToEntry>;

async function buildIntentionalitySnapshot(
  ctx: any,
  options?: {
    windowDays?: ConvexNumberArg;
    timeZoneOffsetMinutes?: ConvexNumberArg;
  },
) {
  const timestamp = now();
  const windowDays = clampIntentionalityWindowDays(options?.windowDays);
  const timeZoneOffsetMinutes = normalizedTimeZoneOffsetMinutes(
    options?.timeZoneOffsetMinutes,
  );
  const cutoffTime = timestamp - windowDays * DAY_MS;

  const observations = (
    await ctx.db
      .query("metricObservations")
      .withIndex("by_subjectType_key_observedAt", (q: any) =>
        q
          .eq("subjectType", INTENTIONALITY_SUBJECT_TYPE)
          .eq("key", INTENTIONALITY_KEY)
          .gte("observedAt", cutoffTime),
      )
      .collect()
  ) as Doc<"metricObservations">[];

  const numericObservations = observations
    .filter(
      (observation: Doc<"metricObservations">) =>
        observation.valueType === "number" &&
        typeof observation.numberValue === "number",
    )
    .sort(
      (left: Doc<"metricObservations">, right: Doc<"metricObservations">) =>
        left.observedAt - right.observedAt,
    );

  const entries: IntentionalityEntry[] = numericObservations.map(
    (observation: Doc<"metricObservations">) =>
      intentionalityObservationToEntry(observation, timeZoneOffsetMinutes),
  );
  const scores = entries.map((entry) => entry.score);
  const todayKey = localDayKey(timestamp, timeZoneOffsetMinutes);
  const yesterdayKey = localDayKey(timestamp - DAY_MS, timeZoneOffsetMinutes);
  const todayScores = entries
    .filter((entry) => entry.dayKey === todayKey)
    .map((entry) => entry.score);
  const yesterdayScores = entries
    .filter((entry) => entry.dayKey === yesterdayKey)
    .map((entry) => entry.score);
  const last24Scores = entries
    .filter((entry) => entry.hourStartMs >= timestamp - DAY_MS)
    .map((entry) => entry.score);
  const currentHourStart = hourStart(timestamp);
  const comparisonWindowStart = currentHourStart - 95 * HOUR_MS;
  const currentHourScore =
    [...entries].reverse().find((entry) => entry.hourStartMs === currentHourStart)
      ?.score ?? null;

  const dailyStats = new Map<
    string,
    { dayKey: string; dayStartMs: number; total: number; count: number }
  >();
  const hourlyStats = new Map<number, { total: number; count: number }>();

  for (const entry of entries) {
    const existingDaily = dailyStats.get(entry.dayKey) ?? {
      dayKey: entry.dayKey,
      dayStartMs: localDayStartMs(entry.hourStartMs, timeZoneOffsetMinutes),
      total: 0,
      count: 0,
    };
    existingDaily.total += entry.score;
    existingDaily.count += 1;
    dailyStats.set(entry.dayKey, existingDaily);

    const existingHourly = hourlyStats.get(entry.hour) ?? { total: 0, count: 0 };
    existingHourly.total += entry.score;
    existingHourly.count += 1;
    hourlyStats.set(entry.hour, existingHourly);
  }

  const dailyAverages = [...dailyStats.values()]
    .sort((left, right) => left.dayStartMs - right.dayStartMs)
    .slice(-windowDays)
    .map((day) => ({
      id: day.dayKey,
      dayKey: day.dayKey,
      dayStartMs: day.dayStartMs,
      average: roundMetric(day.total / day.count),
      count: day.count,
    }));

  const hourlyAverages = Array.from({ length: 24 }, (_, hour) => {
    const stats = hourlyStats.get(hour);
    return {
      id: String(hour),
      hour,
      label: hourLabel(hour),
      average: stats ? roundMetric(stats.total / stats.count) : null,
      count: stats?.count ?? 0,
    };
  });

  const bestHourOfDay =
    hourlyAverages
      .filter(
        (hour): hour is {
          id: string;
          hour: number;
          label: string;
          average: number;
          count: number;
        } => typeof hour.average === "number" && hour.count > 0,
      )
      .sort((left, right) => {
        if (left.average === right.average) {
          return right.count - left.count;
        }
        return right.average - left.average;
      })[0] ?? null;

  const lastSevenDayCutoff = timestamp - 7 * DAY_MS;
  const lastSevenEntries = entries.filter(
    (entry) => entry.hourStartMs >= lastSevenDayCutoff,
  );
  const expectedWindowStart =
    lastSevenEntries[0]?.hourStartMs ?? hourStart(lastSevenDayCutoff);
  const expectedHours = Math.max(
    1,
    Math.min(7 * 24, Math.ceil((timestamp - expectedWindowStart) / HOUR_MS)),
  );
  const responseRate7d = roundMetric(
    ([...new Set(lastSevenEntries.map((entry) => entry.hourStartMs))].length /
      expectedHours) *
      100,
  );

  return {
    generatedAt: timestamp,
    windowDays,
    timeZoneOffsetMinutes,
    totalEntries: entries.length,
    averageScore: roundMetric(averageOf(scores)),
    todayAverage: todayScores.length > 0 ? roundMetric(averageOf(todayScores)) : null,
    yesterdayAverage:
      yesterdayScores.length > 0 ? roundMetric(averageOf(yesterdayScores)) : null,
    deltaFromYesterday:
      todayScores.length > 0 && yesterdayScores.length > 0
        ? roundMetric(averageOf(todayScores) - averageOf(yesterdayScores))
        : null,
    last24Average:
      last24Scores.length > 0 ? roundMetric(averageOf(last24Scores)) : null,
    currentHourScore,
    currentStreakDays: computeLocalDayStreak(
      entries.map((entry) => entry.dayKey),
      timestamp,
      timeZoneOffsetMinutes,
    ),
    responseRate7d,
    bestHourOfDay,
    recentEntries: [...entries]
      .filter((entry) => entry.hourStartMs >= comparisonWindowStart)
      .reverse(),
    dailyAverages,
    hourlyAverages,
    lastRecordedAt: entries[entries.length - 1]?.hourStartMs ?? null,
    lastUpdatedAt: numericObservations[numericObservations.length - 1]?.updatedAt ?? null,
  };
}

async function getIntegrationDoc(ctx: any) {
  const existing = await ctx.db
    .query("intentIntegrationState")
    .withIndex("by_slug", (q: any) => q.eq("slug", DEFAULT_INTEGRATION_SLUG))
    .first();

  if (existing) {
    return existing;
  }

  const timestamp = now();
  const createdId = await ctx.db.insert("intentIntegrationState", {
    slug: DEFAULT_INTEGRATION_SLUG,
    createdAt: timestamp,
    updatedAt: timestamp,
  });

  const created = await ctx.db.get(createdId);
  if (!created) {
    throw new Error("Failed to create integration state.");
  }

  return created;
}

async function getDeviceDoc(ctx: any, deviceId: string) {
  return await ctx.db
    .query("intentDevices")
    .withIndex("by_deviceId", (q: any) => q.eq("deviceId", deviceId))
    .first();
}

function mergeDeviceSettings(
  existing: Doc<"intentDevices"> | null,
  settings: DeviceSettings | undefined,
) {
  return {
    autoStartFocus: settings?.autoStartFocus ?? existing?.autoStartFocus ?? true,
    autoCompleteFocus:
      settings?.autoCompleteFocus ?? existing?.autoCompleteFocus ?? true,
    autoShowReview: settings?.autoShowReview ?? existing?.autoShowReview ?? true,
    startShortcutName:
      settings?.startShortcutName ?? existing?.startShortcutName,
    completeShortcutName:
      settings?.completeShortcutName ?? existing?.completeShortcutName,
    bundleId: settings?.bundleId ?? existing?.bundleId,
  };
}

function buildDeviceHeartbeatPatch(
  device: Doc<"intentDevices">,
  merged: ReturnType<typeof mergeDeviceSettings>,
  timestamp: number,
  options?: {
    recordPresence?: boolean;
  },
) {
  const patch: Partial<Doc<"intentDevices">> = {};

  if (device.bundleId !== merged.bundleId) {
    patch.bundleId = merged.bundleId;
  }
  if (device.autoStartFocus !== merged.autoStartFocus) {
    patch.autoStartFocus = merged.autoStartFocus;
  }
  if (device.autoCompleteFocus !== merged.autoCompleteFocus) {
    patch.autoCompleteFocus = merged.autoCompleteFocus;
  }
  if (device.autoShowReview !== merged.autoShowReview) {
    patch.autoShowReview = merged.autoShowReview;
  }
  if (device.startShortcutName !== merged.startShortcutName) {
    patch.startShortcutName = merged.startShortcutName;
  }
  if (device.completeShortcutName !== merged.completeShortcutName) {
    patch.completeShortcutName = merged.completeShortcutName;
  }

  const shouldRefreshHeartbeat =
    options?.recordPresence === true &&
    (typeof device.lastSeenAt !== "number" ||
      timestamp - device.lastSeenAt >= DEVICE_HEARTBEAT_INTERVAL_MS);

  if (shouldRefreshHeartbeat) {
    patch.lastSeenAt = timestamp;
  }

  if (Object.keys(patch).length > 0) {
    patch.updatedAt = timestamp;
  }

  return patch;
}

async function buildDevicePollState(
  ctx: any,
  device: Doc<"intentDevices">,
  integration?: Doc<"intentIntegrationState">,
) {
  const currentIntegration = integration ?? (await getIntegrationDoc(ctx));

  const activeSession = await ctx.db
    .query("intentSessions")
    .withIndex("by_status_startTimeMs", (q: any) => q.eq("status", "running"))
    .order("desc")
    .first();
  const pendingFocusStart =
    device.autoStartFocus && activeSession?.focusStatus === "pending"
      ? activeSession
      : null;

  const focusStartedSessions = await ctx.db
    .query("intentSessions")
    .withIndex("by_focusStatus_updatedAt", (q: any) => q.eq("focusStatus", "started"))
    .order("desc")
    .take(8);

  const pendingFocusComplete =
    device.autoCompleteFocus
      ? focusStartedSessions.find(
          (session: Doc<"intentSessions">) => session.status === "completed",
        ) ?? null
      : null;

  const pendingReviewSessions = (
    await Promise.all(
      ["pending", "presented"].map((status) =>
        ctx.db
          .query("intentSessions")
          .withIndex("by_reviewStatus_updatedAt", (q: any) =>
            q.eq("reviewStatus", status),
          )
          .order("asc")
          .collect(),
      ),
    )
  ).flat();

  const pendingReview =
    device.autoShowReview
      ? pendingReviewSessions.find((session: Doc<"intentSessions">) =>
          isPendingReviewStatus(session.reviewStatus),
        ) ?? null
      : null;

  const activeReviewDoc = pendingReview
    ? await ctx.db
        .query("intentSessionReviews")
        .withIndex("by_sessionId", (q: any) => q.eq("sessionId", pendingReview._id))
        .first()
    : null;

  return {
    device: {
      id: device.deviceId,
      name: device.name,
      platform: device.platform,
      isDefault: device.isDefault,
      autoStartFocus: device.autoStartFocus,
      autoCompleteFocus: device.autoCompleteFocus,
      autoShowReview: device.autoShowReview,
      startShortcutName: device.startShortcutName ?? null,
      completeShortcutName: device.completeShortcutName ?? null,
      lastSeenAt: device.lastSeenAt ?? null,
    },
    integration: {
      defaultDeviceId: currentIntegration.defaultDeviceId ?? null,
      togglWorkspaceId: currentIntegration.togglWorkspaceId ?? null,
      togglWebhookSubscriptionId:
        currentIntegration.togglWebhookSubscriptionId ?? null,
      togglWebhookUrl: currentIntegration.togglWebhookUrl ?? null,
      togglWebhookValidatedAt:
        currentIntegration.togglWebhookValidatedAt ?? null,
      lastWebhookAt: currentIntegration.lastWebhookAt ?? null,
      lastWebhookAction: currentIntegration.lastWebhookAction ?? null,
      lastWebhookTimeEntryId: currentIntegration.lastWebhookTimeEntryId ?? null,
      lastWebhookError: currentIntegration.lastWebhookError ?? null,
    },
    activeSession: activeSession ? toSessionSummary(activeSession) : null,
    pendingFocusStart: pendingFocusStart ? toSessionSummary(pendingFocusStart) : null,
    pendingFocusComplete: pendingFocusComplete
      ? toSessionSummary(pendingFocusComplete)
      : null,
    pendingReview: pendingReview
      ? {
          ...toSessionSummary(pendingReview),
          existingReview: toReviewSummary(activeReviewDoc),
        }
      : null,
    pendingReviewsCount: pendingReviewSessions.length,
  };
}

async function buildDeviceDashboardState(ctx: any) {
  const runningSessions = await ctx.db
    .query("intentSessions")
    .withIndex("by_status_startTimeMs", (q: any) => q.eq("status", "running"))
    .order("desc")
    .take(2);
  const completedSessionsDesc = await ctx.db
    .query("intentSessions")
    .withIndex("by_status_startTimeMs", (q: any) => q.eq("status", "completed"))
    .order("desc")
    .take(16);

  const recentSessions = [...runningSessions, ...completedSessionsDesc]
    .sort((left, right) => right.startTimeMs - left.startTimeMs)
    .slice(0, 16);

  const recentSessionReviews = await Promise.all(
    recentSessions.map((session) =>
      ctx.db
        .query("intentSessionReviews")
        .withIndex("by_sessionId", (q: any) => q.eq("sessionId", session._id))
        .first(),
    ),
  );

  return {
    generatedAt: now(),
    recentSessions: recentSessions.map((session, index) => ({
      ...toSessionSummary(session),
      existingReview: toReviewSummary(recentSessionReviews[index] ?? null),
    })),
  };
}

export const registerDevice = internalMutation({
  args: {
    deviceName: v.string(),
    platform: v.string(),
    settings: v.optional(v.any()),
  },
  handler: async (ctx, args) => {
    const integration = await getIntegrationDoc(ctx);
    const timestamp = now();
    const deviceId = generateToken("intent_device");
    const deviceSecret = generateToken("intent_secret");
    const merged = mergeDeviceSettings(null, args.settings as DeviceSettings);
    const isDefault = !integration.defaultDeviceId;

    await ctx.db.insert("intentDevices", {
      deviceId,
      deviceSecret,
      name: args.deviceName,
      platform: args.platform,
      bundleId: merged.bundleId,
      autoStartFocus: merged.autoStartFocus,
      autoCompleteFocus: merged.autoCompleteFocus,
      autoShowReview: merged.autoShowReview,
      startShortcutName: merged.startShortcutName,
      completeShortcutName: merged.completeShortcutName,
      lastSeenAt: timestamp,
      isDefault,
      createdAt: timestamp,
      updatedAt: timestamp,
    });

    if (isDefault) {
      await ctx.db.patch(integration._id, {
        defaultDeviceId: deviceId,
        updatedAt: timestamp,
      });
    }

    return {
      deviceId,
      deviceSecret,
      isDefault,
    };
  },
});

export const authenticateDevice = internalQuery({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device || device.deviceSecret !== args.deviceSecret) {
      return null;
    }

    return device;
  },
});

export const heartbeatDevice = internalMutation({
  args: {
    deviceId: v.string(),
    settings: v.optional(v.any()),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device) {
      return null;
    }

    const timestamp = now();
    const merged = mergeDeviceSettings(device, args.settings as DeviceSettings);

    await ctx.db.patch(device._id, {
      bundleId: merged.bundleId,
      autoStartFocus: merged.autoStartFocus,
      autoCompleteFocus: merged.autoCompleteFocus,
      autoShowReview: merged.autoShowReview,
      startShortcutName: merged.startShortcutName,
      completeShortcutName: merged.completeShortcutName,
      lastSeenAt: timestamp,
      updatedAt: timestamp,
    });

    return {
      ...device,
      ...merged,
      lastSeenAt: timestamp,
      updatedAt: timestamp,
    };
  },
});

export const pollDeviceState = internalMutation({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    settings: v.optional(v.any()),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device || device.deviceSecret !== args.deviceSecret) {
      return null;
    }

    const timestamp = now();
    const merged = mergeDeviceSettings(device, args.settings as DeviceSettings);
    const patch = buildDeviceHeartbeatPatch(device, merged, timestamp, {
      recordPresence: true,
    });
    const currentDevice =
      Object.keys(patch).length > 0
        ? {
            ...device,
            ...patch,
          }
        : device;

    if (Object.keys(patch).length > 0) {
      await ctx.db.patch(device._id, patch);
    }

    const integration = await getIntegrationDoc(ctx);
    return await buildDevicePollState(ctx, currentDevice, integration);
  },
});

export const deviceOperationalStateJson = query({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device || device.deviceSecret !== args.deviceSecret) {
      throw new Error("Invalid device credentials.");
    }

    const state = await buildDevicePollState(ctx, device);
    return JSON.stringify(state);
  },
});

export const syncDeviceSettings = mutation({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    settings: v.optional(v.any()),
    recordPresence: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device || device.deviceSecret !== args.deviceSecret) {
      throw new Error("Invalid device credentials.");
    }

    const timestamp = now();
    const merged = mergeDeviceSettings(device, args.settings as DeviceSettings);
    const patch = buildDeviceHeartbeatPatch(device, merged, timestamp, {
      recordPresence: args.recordPresence ?? false,
    });

    if (Object.keys(patch).length > 0) {
      await ctx.db.patch(device._id, patch);
    }

    return true;
  },
});

export const recordIntentionalityFromDevice = mutation({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    score: convexNumber,
    observedAt: v.optional(convexNumber),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device || device.deviceSecret !== args.deviceSecret) {
      throw new Error("Invalid device credentials.");
    }

    const observedAt = normalizedObservedAt(args.observedAt);
    const entry = await upsertHourlyIntentionalityObservation(ctx, {
      hourStartMs: hourStart(observedAt),
      score: clampIntentionalityScore(args.score),
      source: "intent_ios_app",
      sourceDeviceName: device.name,
    });

    return {
      ok: true,
      entry,
    };
  },
});

export const recordHourlyIntentionality = internalMutation({
  args: {
    score: convexNumber,
    observedAt: v.optional(convexNumber),
    source: v.string(),
    sourceDeviceName: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const observedAt = normalizedObservedAt(args.observedAt);
    const entry = await upsertHourlyIntentionalityObservation(ctx, {
      hourStartMs: hourStart(observedAt),
      score: clampIntentionalityScore(args.score),
      source: args.source,
      sourceDeviceName: args.sourceDeviceName,
    });

    return {
      ok: true,
      entry,
    };
  },
});

export const getIntentionalitySnapshotJson = query({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    windowDays: v.optional(convexNumber),
    timeZoneOffsetMinutes: v.optional(convexNumber),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device || device.deviceSecret !== args.deviceSecret) {
      throw new Error("Invalid device credentials.");
    }

    const state = await buildIntentionalitySnapshot(ctx, {
      windowDays: args.windowDays,
      timeZoneOffsetMinutes: args.timeZoneOffsetMinutes,
    });

    return JSON.stringify(state);
  },
});

export const getDeviceIntentionalityState = internalQuery({
  args: {
    windowDays: v.optional(convexNumber),
    timeZoneOffsetMinutes: v.optional(convexNumber),
  },
  handler: async (ctx, args) => {
    return await buildIntentionalitySnapshot(ctx, {
      windowDays: args.windowDays,
      timeZoneOffsetMinutes: args.timeZoneOffsetMinutes,
    });
  },
});

export const updateIntegrationState = internalMutation({
  args: {
    patch: v.any(),
  },
  handler: async (ctx, args) => {
    const integration = await getIntegrationDoc(ctx);
    const timestamp = now();

    await ctx.db.patch(integration._id, {
      ...(args.patch as Record<string, unknown>),
      updatedAt: timestamp,
    });

    return await ctx.db.get(integration._id);
  },
});

export const getIntegrationState = internalQuery({
  args: {},
  handler: async (ctx) => {
    return await getIntegrationDoc(ctx);
  },
});

export const recordWebhookEvent = internalMutation({
  args: {
    dedupeKey: v.string(),
    entity: v.string(),
    action: v.string(),
    entityId: v.string(),
    workspaceId: v.optional(v.number()),
    happenedAt: v.optional(v.number()),
    payloadJson: v.string(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("intentWebhookEvents")
      .withIndex("by_dedupeKey", (q: any) => q.eq("dedupeKey", args.dedupeKey))
      .first();

    if (existing) {
      return { isDuplicate: true, eventId: existing._id };
    }

    const timestamp = now();
    const eventId = await ctx.db.insert("intentWebhookEvents", {
      dedupeKey: args.dedupeKey,
      entity: args.entity,
      action: args.action,
      entityId: args.entityId,
      workspaceId: args.workspaceId,
      happenedAt: args.happenedAt,
      receivedAt: timestamp,
      payloadJson: args.payloadJson,
    });

    return { isDuplicate: false, eventId };
  },
});

export const upsertSessionFromToggl = internalMutation({
  args: {
    action: v.string(),
    timeEntry: v.any(),
    projectName: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const timeEntry = args.timeEntry as TogglTimeEntry;
    const sourceTimeEntryId = String(timeEntry.id);
    const existing = await ctx.db
      .query("intentSessions")
      .withIndex("by_sourceTimeEntryId", (q: any) =>
        q.eq("sourceTimeEntryId", sourceTimeEntryId),
      )
      .first();

    const timestamp = now();
    const stopTimeMs = timeEntry.stop ? Date.parse(timeEntry.stop) : undefined;
    const status =
      args.action === "deleted"
        ? "deleted"
        : stopTimeMs
          ? "completed"
          : "running";

    let focusStatus = existing?.focusStatus ?? "idle";
    if (status === "running" && !existing) {
      focusStatus = "pending";
    } else if (status === "running" && existing?.focusStatus === "completed") {
      focusStatus = "pending";
    } else if (!stopTimeMs && focusStatus === "idle") {
      focusStatus = "pending";
    } else if (status !== "running" && !existing) {
      focusStatus = "idle";
    }

    let reviewStatus = existing?.reviewStatus ?? "idle";
    if (status === "completed" && (!existing || existing.reviewStatus === "idle")) {
      reviewStatus = "pending";
    } else if (status === "running") {
      reviewStatus = "idle";
    } else if (status === "deleted") {
      reviewStatus = existing?.reviewStatus ?? "skipped";
    }

    const patch = {
      source: "toggl",
      sourceTimeEntryId,
      workspaceId: timeEntry.workspace_id,
      togglUserId: timeEntry.user_id,
      togglProjectId: timeEntry.project_id,
      projectName: args.projectName ?? existing?.projectName,
      togglTaskId: timeEntry.task_id,
      description: timeEntry.description,
      tagJson: JSON.stringify(timeEntry.tags ?? []),
      billable: timeEntry.billable,
      startTimeMs: Date.parse(timeEntry.start),
      stopTimeMs,
      durationMs:
        typeof timeEntry.duration === "number" && timeEntry.duration >= 0
          ? timeEntry.duration * 1000
          : stopTimeMs && Date.parse(timeEntry.start) <= stopTimeMs
            ? stopTimeMs - Date.parse(timeEntry.start)
            : undefined,
      status,
      focusStatus,
      reviewStatus,
      lastWebhookAction: args.action,
      sourceUpdatedAt: timeEntry.at ? Date.parse(timeEntry.at) : timestamp,
      updatedAt: timestamp,
    };

    let sessionId: Id<"intentSessions">;
    let lifecycle: "started" | "stopped" | "updated" | "created_completed" | "deleted";

    if (existing) {
      await ctx.db.patch(existing._id, patch);
      sessionId = existing._id;

      if (existing.status === "running" && status === "completed") {
        lifecycle = "stopped";
      } else if (status === "deleted") {
        lifecycle = "deleted";
      } else {
        lifecycle = "updated";
      }
    } else {
      sessionId = await ctx.db.insert("intentSessions", {
        ...patch,
        createdAt: timestamp,
      });

      lifecycle = status === "running" ? "started" : "created_completed";
    }

    const session = await ctx.db.get(sessionId);
    if (!session) {
      throw new Error("Failed to load session after upsert.");
    }

    return {
      sessionId,
      lifecycle,
      session: toSessionSummary(session),
    };
  },
});

export const markFocusStarted = internalMutation({
  args: {
    sessionId: v.string(),
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const sessionId = args.sessionId as Id<"intentSessions">;
    const session = await ctx.db.get(sessionId);
    if (!session) {
      return null;
    }

    const timestamp = now();
    await ctx.db.patch(sessionId, {
      focusStatus: "started",
      focusStartedAt: timestamp,
      focusDeviceId: args.deviceId,
      updatedAt: timestamp,
    });

    return await ctx.db.get(sessionId);
  },
});

export const markSessionDeletedBySourceId = internalMutation({
  args: {
    action: v.string(),
    sourceTimeEntryId: v.string(),
    sourceUpdatedAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const session = await ctx.db
      .query("intentSessions")
      .withIndex("by_sourceTimeEntryId", (q: any) =>
        q.eq("sourceTimeEntryId", args.sourceTimeEntryId),
      )
      .first();

    if (!session) {
      return null;
    }

    const timestamp = now();
    await ctx.db.patch(session._id, {
      status: "deleted",
      reviewStatus:
        session.reviewStatus === "submitted" ? "submitted" : "skipped",
      lastWebhookAction: args.action,
      sourceUpdatedAt: args.sourceUpdatedAt ?? timestamp,
      updatedAt: timestamp,
    });

    return await ctx.db.get(session._id);
  },
});

export const markFocusCompleted = internalMutation({
  args: {
    sessionId: v.string(),
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const sessionId = args.sessionId as Id<"intentSessions">;
    const session = await ctx.db.get(sessionId);
    if (!session) {
      return null;
    }

    const timestamp = now();
    await ctx.db.patch(sessionId, {
      focusStatus: "completed",
      focusCompletedAt: timestamp,
      focusDeviceId: args.deviceId,
      updatedAt: timestamp,
    });

    return await ctx.db.get(sessionId);
  },
});

export const markReviewPresented = internalMutation({
  args: {
    sessionId: v.string(),
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const sessionId = args.sessionId as Id<"intentSessions">;
    const session = await ctx.db.get(sessionId);
    if (!session) {
      return null;
    }

    const timestamp = now();
    await ctx.db.patch(sessionId, {
      reviewStatus: "presented",
      reviewPresentedAt: timestamp,
      reviewPresentedDeviceId: args.deviceId,
      updatedAt: timestamp,
    });

    return await ctx.db.get(sessionId);
  },
});

export const markReviewSkipped = internalMutation({
  args: {
    sessionId: v.string(),
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    // deviceId is authenticated at the HTTP boundary; kept for parity with other review mutations
    void args.deviceId;

    const sessionId = args.sessionId as Id<"intentSessions">;
    const session = await ctx.db.get(sessionId);
    if (!session) {
      return null;
    }

    // already closed out - treat as success so clients can dismiss idempotently
    if (session.reviewStatus === "submitted" || session.reviewStatus === "skipped") {
      return session;
    }

    if (!isPendingReviewStatus(session.reviewStatus)) {
      return session;
    }

    const timestamp = now();
    await ctx.db.patch(sessionId, {
      reviewStatus: "skipped",
      updatedAt: timestamp,
    });

    return await ctx.db.get(sessionId);
  },
});

export const submitReview = internalMutation({
  args: {
    sessionId: v.string(),
    review: v.any(),
  },
  handler: async (ctx, args) => {
    const sessionId = args.sessionId as Id<"intentSessions">;
    const session = await ctx.db.get(sessionId);
    if (!session) {
      throw new Error("Session not found.");
    }

    const timestamp = now();
    const reviewData = args.review as {
      numericMetrics?: Record<string, number>;
      countMetrics?: Record<string, number>;
      booleanMetrics?: Record<string, boolean>;
      taskCategory?: string;
      whatWentWell?: string;
      whatDidntGoWell?: string;
      projectName?: string;
    };

    if (reviewData.projectName !== undefined) {
      await ctx.db.patch(sessionId, {
        projectName: reviewData.projectName,
      });
    }

    const reviewPatch = {
      taskCategory: reviewData.taskCategory?.trim() || undefined,
      numericMetricsJson: JSON.stringify(reviewData.numericMetrics ?? {}),
      countMetricsJson: JSON.stringify(reviewData.countMetrics ?? {}),
      booleanMetricsJson: JSON.stringify(reviewData.booleanMetrics ?? {}),
      whatWentWell: reviewData.whatWentWell,
      whatDidntGoWell: reviewData.whatDidntGoWell,
    };

    const existing = await ctx.db
      .query("intentSessionReviews")
      .withIndex("by_sessionId", (q: any) => q.eq("sessionId", sessionId))
      .first();

    if (existing) {
      await ctx.db.patch(existing._id, {
        ...reviewPatch,
        updatedAt: timestamp,
      });
    } else {
      await ctx.db.insert("intentSessionReviews", {
        sessionId,
        ...reviewPatch,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    }

    await replaceMetricObservationsForIntentSession(ctx, session, {
      numericMetrics: reviewData.numericMetrics ?? {},
      countMetrics: reviewData.countMetrics ?? {},
      booleanMetrics: reviewData.booleanMetrics ?? {},
      taskCategory: reviewData.taskCategory,
    });

    await ctx.db.patch(sessionId, {
      reviewStatus: "submitted",
      reviewSubmittedAt: timestamp,
      updatedAt: timestamp,
    });

    return await ctx.db.get(sessionId);
  },
});

export const rebuildUnifiedMetricObservations = internalMutation({
  args: {},
  handler: async (ctx) => {
    const existingObservations = await ctx.db.query("metricObservations").collect();
    for (const observation of existingObservations) {
      await ctx.db.delete(observation._id);
    }

    const events = await ctx.db.query("events").collect();
    let rebuiltEventSubjects = 0;
    for (const event of events) {
      const metrics = await ctx.db
        .query("metricValues")
        .withIndex("by_eventId", (q: any) => q.eq("eventId", event._id))
        .collect();

      if (metrics.length === 0) {
        continue;
      }

      await replaceMetricObservationsForEvent(
        ctx,
        event,
        metrics.reduce(
          (acc, metric) => {
            acc[metric.key] = metric.value;
            return acc;
          },
          {} as Record<string, number | boolean | string>,
        ),
      );
      rebuiltEventSubjects += 1;
    }

    const reviews = await ctx.db.query("intentSessionReviews").collect();
    let rebuiltSessionSubjects = 0;
    for (const review of reviews) {
      const session = await ctx.db.get(review.sessionId);
      if (!session) {
        continue;
      }

      const normalized = normalizedReviewPayload(review);
      await replaceMetricObservationsForIntentSession(ctx, session, normalized);
      rebuiltSessionSubjects += 1;
    }

    const totalObservations = (await ctx.db.query("metricObservations").collect()).length;
    return {
      ok: true,
      rebuiltEventSubjects,
      rebuiltSessionSubjects,
      totalObservations,
    };
  },
});

export const getDevicePollState = internalQuery({
  args: {
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const device = await getDeviceDoc(ctx, args.deviceId);
    if (!device) {
      return null;
    }
    return await buildDevicePollState(ctx, device);
  },
});

export const getDeviceDashboardState = internalQuery({
  args: {},
  handler: async (ctx) => {
    return await buildDeviceDashboardState(ctx);
  },
});

export const getDeviceMetricsState = internalQuery({
  args: {
    windowDays: v.optional(v.number()),
    timeZoneOffsetMinutes: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const timestamp = now();
    const timeZoneOffsetMinutes = args.timeZoneOffsetMinutes ?? 0;
    const windowDays = clampMetricsWindowDays(args.windowDays);
    const cutoffTime = timestamp - windowDays * 24 * 60 * 60 * 1000;

    const reviewedSessionsDesc = await ctx.db
      .query("intentSessions")
      .withIndex("by_reviewStatus_updatedAt", (q: any) =>
        q.eq("reviewStatus", "submitted").gte("updatedAt", cutoffTime),
      )
      .order("desc")
      .collect();
    const completedSessionsDesc = await ctx.db
      .query("intentSessions")
      .withIndex("by_status_startTimeMs", (q: any) =>
        q.eq("status", "completed").gte("startTimeMs", cutoffTime),
      )
      .order("desc")
      .collect();

    const pendingReviewSessions = (
      await Promise.all(
        ["pending", "presented"].map((status) =>
          ctx.db
            .query("intentSessions")
            .withIndex("by_reviewStatus_updatedAt", (q: any) =>
              q.eq("reviewStatus", status),
            )
            .collect(),
        ),
      )
    ).flat();

    const relevantReviewedSessions = reviewedSessionsDesc;
    const relevantCompletedSessions = completedSessionsDesc;

    const observations = (
      await ctx.db
        .query("metricObservations")
        .withIndex("by_subjectType_observedAt", (q: any) =>
          q.eq("subjectType", "intentSession").gte("observedAt", cutoffTime),
        )
        .collect()
    )
      .sort((left, right) => left.observedAt - right.observedAt);

    const signalBuckets = new Map<string, number[]>();
    const categoryCounts = new Map<string, number>();

    for (const observation of observations) {
      if (observation.valueType === "number" && typeof observation.numberValue === "number") {
        const existing = signalBuckets.get(observation.key) ?? [];
        existing.push(observation.numberValue);
        signalBuckets.set(observation.key, existing);
      }

      if (
        observation.key === "taskCategory" &&
        observation.valueType === "string" &&
        typeof observation.stringValue === "string" &&
        observation.stringValue.trim().length > 0
      ) {
        const normalized = observation.stringValue.trim();
        categoryCounts.set(normalized, (categoryCounts.get(normalized) ?? 0) + 1);
      }
    }

    // per-local-day buckets across the whole window: numeric keys average, count keys sum
    const dailySignalBuckets = new Map<number, Map<string, number[]>>();
    for (const observation of observations) {
      if (observation.valueType !== "number" || typeof observation.numberValue !== "number") {
        continue;
      }
      const dayStart = localDayStartMs(observation.observedAt, timeZoneOffsetMinutes);
      const dayBucket = dailySignalBuckets.get(dayStart) ?? new Map<string, number[]>();
      const values = dayBucket.get(observation.key) ?? [];
      values.push(observation.numberValue);
      dayBucket.set(observation.key, values);
      dailySignalBuckets.set(dayStart, dayBucket);
    }

    const signalDailySeries = [...dailySignalBuckets.entries()]
      .sort((left, right) => left[0] - right[0])
      .map(([dayStart, dayBucket]) => ({
        id: String(dayStart),
        dayStart,
        metrics: Object.fromEntries(
          [...dayBucket.entries()].map(([key, values]) => [
            key,
            INTENT_COUNT_METRIC_KEYS.has(key)
              ? roundMetric(values.reduce((sum, value) => sum + value, 0))
              : roundMetric(averageOf(values)),
          ]),
        ),
      }));

    // per-local-day deep work totals from completed sessions across the whole window
    const dailyDurationBuckets = new Map<number, { durationMs: number; sessionCount: number }>();
    for (const session of relevantCompletedSessions) {
      const dayStart = localDayStartMs(session.startTimeMs, timeZoneOffsetMinutes);
      const bucket = dailyDurationBuckets.get(dayStart) ?? { durationMs: 0, sessionCount: 0 };
      bucket.durationMs += sessionDurationMs(session);
      bucket.sessionCount += 1;
      dailyDurationBuckets.set(dayStart, bucket);
    }

    const dailyDurationSeries = [...dailyDurationBuckets.entries()]
      .sort((left, right) => left[0] - right[0])
      .map(([dayStart, bucket]) => ({
        id: String(dayStart),
        dayStart,
        durationMs: bucket.durationMs,
        sessionCount: bucket.sessionCount,
      }));

    const signalAverages = [...signalBuckets.entries()]
      .filter(([key]) => !INTENT_COUNT_METRIC_KEYS.has(key))
      .map(([key, values]) => {
        const recentSlice = values.slice(-Math.min(4, values.length));
        const previousSlice = values.slice(
          Math.max(0, values.length - recentSlice.length * 2),
          Math.max(0, values.length - recentSlice.length),
        );
        const average = roundMetric(averageOf(values));
        const previousAverage =
          previousSlice.length > 0 ? roundMetric(averageOf(previousSlice)) : null;

        return {
          id: key,
          key,
          title: metricTitle(key),
          average,
          count: values.length,
          deltaFromPrevious:
            previousAverage === null ? null : roundMetric(average - previousAverage),
        };
      })
      .sort((left, right) => {
        const leftIndex = metricSortIndex(left.key);
        const rightIndex = metricSortIndex(right.key);
        if (leftIndex !== rightIndex) {
          return leftIndex - rightIndex;
        }
        return left.title.localeCompare(right.title);
      });

    const dominantCategory = [...categoryCounts.entries()].sort((left, right) => {
      if (left[1] === right[1]) {
        return left[0].localeCompare(right[0]);
      }
      return right[1] - left[1];
    })[0]?.[0] ?? null;

    const totalCategoryCount = [...categoryCounts.values()].reduce(
      (sum, value) => sum + value,
      0,
    );
    const categoryBreakdown = [...categoryCounts.entries()]
      .sort((left, right) => {
        if (left[1] === right[1]) {
          return left[0].localeCompare(right[0]);
        }
        return right[1] - left[1];
      })
      .slice(0, 6)
      .map(([category, count]) => ({
        id: category,
        key: category,
        label: category,
        count,
        share: totalCategoryCount > 0 ? roundMetric((count / totalCategoryCount) * 100) : 0,
      }));

    const reviewedSessionCards = (
      await Promise.all(
        relevantReviewedSessions.slice(0, 14).map(async (session) => {
          const review = await ctx.db
            .query("intentSessionReviews")
            .withIndex("by_sessionId", (q: any) => q.eq("sessionId", session._id))
            .first();
          if (!review) {
            return null;
          }

          const normalized = normalizedReviewPayload(review);
          return {
            id: session._id,
            sessionId: session._id,
            title: session.description ?? "Untitled session",
            observedAt: session.startTimeMs,
            durationMs: sessionDurationMs(session),
            taskCategory: normalized.taskCategory || "Uncategorized",
            metrics: {
              ...Object.fromEntries(
                Object.entries(normalized.numericMetrics).map(([key, value]) => [key, value]),
              ),
              ...Object.fromEntries(
                Object.entries(normalized.countMetrics).map(([key, value]) => [key, value]),
              ),
            },
            focus: normalized.numericMetrics.focus ?? null,
            energy: normalized.numericMetrics.energy ?? null,
            distractions: normalized.countMetrics.distractions ?? null,
            whatWentWell: normalized.whatWentWell,
            whatDidntGoWell: normalized.whatDidntGoWell,
          };
        }),
      )
    ).filter(
      (
        card,
      ): card is {
        id: string;
        sessionId: string;
        title: string;
        observedAt: number;
        durationMs: number;
        taskCategory: string;
        metrics: Record<string, number>;
        focus: number | null;
        energy: number | null;
        distractions: number | null;
        whatWentWell: string;
        whatDidntGoWell: string;
      } => card !== null,
    );

    const trendSeries = [...reviewedSessionCards]
      .sort((left, right) => left.observedAt - right.observedAt)
      .slice(-12)
      .map((card) => ({
        id: card.id,
        sessionId: card.sessionId,
        title: card.title,
        observedAt: card.observedAt,
        durationMs: card.durationMs,
        taskCategory: card.taskCategory,
        metrics: card.metrics,
      }));

    const reflectionHighlights = reviewedSessionCards.slice(0, 4).map((card) => ({
      id: card.id,
      sessionId: card.sessionId,
      title: card.title,
      observedAt: card.observedAt,
      taskCategory: card.taskCategory,
      focus: card.focus,
      energy: card.energy,
      distractions: card.distractions,
      whatWentWell: card.whatWentWell,
      whatDidntGoWell: card.whatDidntGoWell,
    }));

    const distractionValues = reviewedSessionCards
      .map((card) => card.distractions)
      .filter((value): value is number => typeof value === "number");
    const dailyVolumeMap = new Map<number, { reviewedCount: number; totalFocus: number; focusCount: number }>();
    for (const card of reviewedSessionCards) {
      const dayStart = startOfUTCDay(card.observedAt);
      const existing = dailyVolumeMap.get(dayStart) ?? {
        reviewedCount: 0,
        totalFocus: 0,
        focusCount: 0,
      };
      existing.reviewedCount += 1;
      if (typeof card.focus === "number") {
        existing.totalFocus += card.focus;
        existing.focusCount += 1;
      }
      dailyVolumeMap.set(dayStart, existing);
    }

    const dailyVolume = [...dailyVolumeMap.entries()]
      .sort((left, right) => left[0] - right[0])
      .slice(-10)
      .map(([dayStart, value]) => ({
        id: String(dayStart),
        dayStart,
        reviewedCount: value.reviewedCount,
        averageFocus:
          value.focusCount > 0 ? roundMetric(value.totalFocus / value.focusCount) : null,
      }));
    const averageDurationMs = roundMetric(
      averageOf(relevantReviewedSessions.map((session) => sessionDurationMs(session))),
      0,
    );
    const qualityComponents = ["focus", "discipline", "adherence", "intentionality"]
      .map((key) => signalAverages.find((signal) => signal.key == key)?.average)
      .filter((value): value is number => typeof value === "number");

    return {
      generatedAt: timestamp,
      windowDays,
      reviewedSessions: relevantReviewedSessions.length,
      completedSessions: relevantCompletedSessions.length,
      pendingReviews: pendingReviewSessions.length,
      reviewCompletionRate:
        relevantCompletedSessions.length > 0
          ? roundMetric((relevantReviewedSessions.length / relevantCompletedSessions.length) * 100)
          : 0,
      averageDurationMs,
      averageDistractions: roundMetric(averageOf(distractionValues)),
      qualityScore: roundMetric(averageOf(qualityComponents)),
      dominantCategory,
      streakDays: computeDayStreak(
        relevantReviewedSessions.map((session) => observedDayKey(session.startTimeMs)),
      ),
      signalAverages,
      signalDailySeries,
      dailyDurationSeries,
      categoryBreakdown,
      trendSeries,
      dailyVolume,
      reflectionHighlights,
      lastReviewedAt: relevantReviewedSessions[0]?.startTimeMs ?? null,
      lastUpdatedAt: relevantReviewedSessions[0]?.updatedAt ?? null,
    };
  },
});

export const getDeviceDailyReportContext = internalQuery({
  args: {
    startTimeMs: v.number(),
    endTimeMs: v.number(),
  },
  handler: async (ctx, args) => {
    const timestamp = now();
    const startTimeMs = Math.max(0, Math.round(args.startTimeMs));
    const endTimeMs = Math.max(startTimeMs, Math.round(args.endTimeMs));

    const completedSessions = await ctx.db
      .query("intentSessions")
      .withIndex("by_status_startTimeMs", (q: any) => q.eq("status", "completed"))
      .order("desc")
      .collect();
    const runningSessions = await ctx.db
      .query("intentSessions")
      .withIndex("by_status_startTimeMs", (q: any) => q.eq("status", "running"))
      .order("desc")
      .collect();

    const relevantSessions = [...completedSessions, ...runningSessions]
      .filter((session) => {
        const overlapDurationMs = sessionOverlapDurationMs(
          session,
          startTimeMs,
          endTimeMs,
          Math.min(timestamp, endTimeMs),
        );
        return overlapDurationMs > 0;
      })
      .sort((left, right) => left.startTimeMs - right.startTimeMs);

    const sessionReviews = await Promise.all(
      relevantSessions.map((session) =>
        ctx.db
          .query("intentSessionReviews")
          .withIndex("by_sessionId", (q: any) => q.eq("sessionId", session._id))
          .first(),
      ),
    );

    const reviewSummaries = sessionReviews.map((review) => toReviewSummary(review ?? null));
    const trackedDurationMs = relevantSessions.reduce((sum, session) => {
      return (
        sum +
        sessionOverlapDurationMs(
          session,
          startTimeMs,
          endTimeMs,
          Math.min(timestamp, endTimeMs),
        )
      );
    }, 0);

    const focusScores = reviewSummaries
      .map((review) => review?.numericMetrics.focus)
      .filter((value): value is number => typeof value === "number");
    const adherenceScores = reviewSummaries
      .map((review) => review?.numericMetrics.adherence)
      .filter((value): value is number => typeof value === "number");
    const energyScores = reviewSummaries
      .map((review) => review?.numericMetrics.energy)
      .filter((value): value is number => typeof value === "number");
    const distractionCounts = reviewSummaries
      .map((review) => review?.countMetrics.distractions)
      .filter((value): value is number => typeof value === "number");

    const categoryCounts = reviewSummaries.reduce((result, review) => {
      const taskCategory = review?.taskCategory?.trim();
      if (!taskCategory) {
        return result;
      }

      result.set(taskCategory, (result.get(taskCategory) ?? 0) + 1);
      return result;
    }, new Map<string, number>());

    const topCategories = [...categoryCounts.entries()]
      .sort((left, right) => {
        if (left[1] === right[1]) {
          return left[0].localeCompare(right[0]);
        }
        return right[1] - left[1];
      })
      .slice(0, 6)
      .map(([label, count]) => ({
        id: label,
        label,
        count,
      }));

    return {
      generatedAt: timestamp,
      startTimeMs,
      endTimeMs,
      trackedDurationMs,
      totalSessions: relevantSessions.length,
      completedSessions: relevantSessions.filter((session) => session.status === "completed")
        .length,
      reviewedSessions: reviewSummaries.filter((review) => review !== null).length,
      pendingReviews: relevantSessions.filter((session) =>
        isPendingReviewStatus(session.reviewStatus),
      ).length,
      averageFocus:
        focusScores.length > 0 ? roundMetric(averageOf(focusScores)) : null,
      averageAdherence:
        adherenceScores.length > 0 ? roundMetric(averageOf(adherenceScores)) : null,
      averageEnergy:
        energyScores.length > 0 ? roundMetric(averageOf(energyScores)) : null,
      totalDistractions: distractionCounts.reduce((sum, value) => sum + value, 0),
      topCategories,
      sessions: relevantSessions.map((session, index) => ({
        ...toSessionSummary(session),
        durationWithinWindowMs: sessionOverlapDurationMs(
          session,
          startTimeMs,
          endTimeMs,
          Math.min(timestamp, endTimeMs),
        ),
        existingReview: reviewSummaries[index],
      })),
    };
  },
});

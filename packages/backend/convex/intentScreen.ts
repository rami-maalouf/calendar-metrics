import { v } from "convex/values";

import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery } from "./_generated/server";

const SCREEN_SOURCE = "biome_app_in_focus";
const MAX_EVENT_SECONDS = 6 * 60 * 60;
const CAP_EVENT_SECONDS = 3 * 60 * 60;
const TOP_APPS_LIMIT = 8;

const screenAppValidator = v.object({
  bundleId: v.string(),
  title: v.string(),
  seconds: v.number(),
});

const screenHourValidator = v.object({
  hourOfDay: v.number(),
  hourStartMs: v.number(),
  totalSeconds: v.number(),
  topApps: v.array(screenAppValidator),
});

type ScreenApp = {
  bundleId: string;
  title: string;
  seconds: number;
};

type ScreenHour = {
  hourOfDay: number;
  hourStartMs: number;
  totalSeconds: number;
  topApps: ScreenApp[];
};

function now() {
  return Date.now();
}

function clampNonNegative(value: number) {
  if (!Number.isFinite(value) || value < 0) {
    return 0;
  }
  return value;
}

function formatHours(seconds: number) {
  const hours = seconds / 3600;
  if (hours >= 10) {
    return `${hours.toFixed(0)}h`;
  }
  if (hours >= 1) {
    return `${hours.toFixed(1)}h`;
  }
  const minutes = Math.round(seconds / 60);
  return `${minutes}m`;
}

function buildNotificationBody(dayKey: string, totalSeconds: number, topApps: ScreenApp[]) {
  const parts = topApps.slice(0, 3).map((app) => `${app.title} ${formatHours(app.seconds)}`);
  const suffix = parts.length > 0 ? ` · ${parts.join(" · ")}` : "";
  return `${dayKey} on iPhone: ${formatHours(totalSeconds)}${suffix}`;
}

function parseTopAppsJson(raw: string): ScreenApp[] {
  try {
    const parsed = JSON.parse(raw) as ScreenApp[];
    if (!Array.isArray(parsed)) {
      return [];
    }
    return parsed
      .filter(
        (row) =>
          typeof row?.bundleId === "string" &&
          typeof row?.title === "string" &&
          typeof row?.seconds === "number",
      )
      .map((row) => ({
        bundleId: row.bundleId,
        title: row.title,
        seconds: clampNonNegative(row.seconds),
      }));
  } catch {
    return [];
  }
}

function parseHourlyTotalsJson(raw: string): number[] {
  try {
    const parsed = JSON.parse(raw) as number[];
    if (!Array.isArray(parsed) || parsed.length !== 24) {
      return Array.from({ length: 24 }, () => 0);
    }
    return parsed.map((value) => clampNonNegative(Number(value) || 0));
  } catch {
    return Array.from({ length: 24 }, () => 0);
  }
}

function normalizeApps(apps: ScreenApp[]) {
  const byBundle = new Map<string, ScreenApp>();
  for (const app of apps) {
    const bundleId = app.bundleId.trim();
    if (!bundleId) {
      continue;
    }
    const seconds = clampNonNegative(app.seconds);
    if (seconds <= 0) {
      continue;
    }
    const title = app.title.trim() || bundleId;
    const existing = byBundle.get(bundleId);
    if (existing) {
      existing.seconds += seconds;
      if (title.length > existing.title.length) {
        existing.title = title;
      }
    } else {
      byBundle.set(bundleId, { bundleId, title, seconds });
    }
  }

  return [...byBundle.values()].sort((a, b) => b.seconds - a.seconds);
}

function normalizeHours(hours: ScreenHour[]) {
  const byHour = new Map<number, ScreenHour>();
  for (const hour of hours) {
    const hourOfDay = Math.floor(hour.hourOfDay);
    if (hourOfDay < 0 || hourOfDay > 23) {
      continue;
    }
    const totalSeconds = clampNonNegative(hour.totalSeconds);
    if (totalSeconds <= 0) {
      continue;
    }
    byHour.set(hourOfDay, {
      hourOfDay,
      hourStartMs: Math.floor(hour.hourStartMs),
      totalSeconds,
      topApps: normalizeApps(hour.topApps).slice(0, TOP_APPS_LIMIT),
    });
  }

  return [...byHour.values()].sort((a, b) => a.hourOfDay - b.hourOfDay);
}

// single-tenant intent: all paired devices read/write the same phone screen rollups
const SHARED_SCREEN_OWNER_ID = "intent_shared";

async function getDeviceDoc(ctx: any, deviceId: string) {
  return await ctx.db
    .query("intentDevices")
    .withIndex("by_deviceId", (q: any) => q.eq("deviceId", deviceId))
    .unique();
}

async function authenticateScreenDevice(ctx: any, deviceId: string, deviceSecret: string) {
  const device = await getDeviceDoc(ctx, deviceId);
  if (!device || device.deviceSecret !== deviceSecret) {
    return null;
  }
  return device;
}

async function findScreenDay(
  ctx: any,
  ownerCandidates: string[],
  dayKey: string | undefined,
) {
  if (dayKey) {
    for (const ownerDeviceId of ownerCandidates) {
      const rows = await ctx.db
        .query("intentScreenDays")
        .withIndex("by_owner_dayKey", (q: any) =>
          q.eq("ownerDeviceId", ownerDeviceId).eq("dayKey", dayKey),
        )
        .collect();
      const day = rows.sort(
        (a: Doc<"intentScreenDays">, b: Doc<"intentScreenDays">) =>
          b.collectedAt - a.collectedAt,
      )[0];
      if (day) {
        return day as Doc<"intentScreenDays">;
      }
    }
    return null;
  }

  const byDayKey = new Map<string, Doc<"intentScreenDays">>();
  for (const ownerDeviceId of ownerCandidates) {
    const rows = await ctx.db
      .query("intentScreenDays")
      .withIndex("by_owner_collectedAt", (q: any) => q.eq("ownerDeviceId", ownerDeviceId))
      .order("desc")
      .take(90);
    for (const row of rows) {
      const existing = byDayKey.get(row.dayKey);
      if (!existing || row.collectedAt > existing.collectedAt) {
        byDayKey.set(row.dayKey, row);
      }
    }
  }

  return (
    [...byDayKey.values()].sort((a, b) => b.dayKey.localeCompare(a.dayKey))[0] ??
    null
  );
}

function screenOwnerCandidates(deviceId: string) {
  return [SHARED_SCREEN_OWNER_ID, deviceId];
}

async function deleteDayChildren(
  ctx: any,
  ownerDeviceId: string,
  dayKey: string,
  sourceDeviceId: string,
) {
  const apps = await ctx.db
    .query("intentScreenAppDays")
    .withIndex("by_owner_day_sourceDevice", (q: any) =>
      q
        .eq("ownerDeviceId", ownerDeviceId)
        .eq("dayKey", dayKey)
        .eq("sourceDeviceId", sourceDeviceId),
    )
    .collect();
  for (const row of apps) {
    await ctx.db.delete(row._id);
  }

  const hours = await ctx.db
    .query("intentScreenHours")
    .withIndex("by_owner_day_sourceDevice", (q: any) =>
      q
        .eq("ownerDeviceId", ownerDeviceId)
        .eq("dayKey", dayKey)
        .eq("sourceDeviceId", sourceDeviceId),
    )
    .collect();
  for (const row of hours) {
    await ctx.db.delete(row._id);
  }
}

function serializeDay(
  day: Doc<"intentScreenDays">,
  hours?: Array<{
    hourOfDay: number;
    hourStartMs: number;
    totalSeconds: number;
    topApps: ScreenApp[];
  }>,
) {
  return {
    dayKey: day.dayKey,
    source: day.source,
    sourceDeviceId: day.sourceDeviceId,
    platform: day.platform,
    totalSeconds: day.totalSeconds,
    eventCount: day.eventCount,
    cleanedEventCount: day.cleanedEventCount,
    topApps: parseTopAppsJson(day.topAppsJson),
    hourlyTotals: parseHourlyTotalsJson(day.hourlyTotalsJson),
    hours: (hours ?? []).map((hour) => ({
      hourOfDay: hour.hourOfDay,
      hourStartMs: hour.hourStartMs,
      totalSeconds: hour.totalSeconds,
      topApps: hour.topApps,
    })),
    notificationBody: day.notificationBody,
    notificationDeliveredAt: day.notificationDeliveredAt ?? null,
    timeZoneOffsetMinutes: day.timeZoneOffsetMinutes,
    collectedAt: day.collectedAt,
  };
}

export const ingestScreenDay = internalMutation({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    dayKey: v.string(),
    sourceDeviceId: v.string(),
    platform: v.optional(v.string()),
    totalSeconds: v.number(),
    eventCount: v.number(),
    cleanedEventCount: v.number(),
    topApps: v.array(screenAppValidator),
    hourlyTotals: v.array(v.number()),
    hours: v.array(screenHourValidator),
    apps: v.array(screenAppValidator),
    timeZoneOffsetMinutes: v.number(),
    notificationBody: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const device = await authenticateScreenDevice(ctx, args.deviceId, args.deviceSecret);
    if (!device) {
      throw new Error("Invalid device credentials.");
    }

    if (!/^\d{4}-\d{2}-\d{2}$/.test(args.dayKey)) {
      throw new Error("dayKey must be YYYY-MM-DD.");
    }

    const sourceDeviceId = args.sourceDeviceId.trim();
    if (!sourceDeviceId) {
      throw new Error("sourceDeviceId is required.");
    }

    const ownerDeviceId = SHARED_SCREEN_OWNER_ID;
    const topApps = normalizeApps(args.topApps).slice(0, TOP_APPS_LIMIT);
    const apps = normalizeApps(args.apps);
    const hours = normalizeHours(args.hours);
    const hourlyTotals =
      args.hourlyTotals.length === 24
        ? args.hourlyTotals.map((value) => clampNonNegative(value))
        : Array.from({ length: 24 }, (_, hourOfDay) => {
            const match = hours.find((hour) => hour.hourOfDay === hourOfDay);
            return match?.totalSeconds ?? 0;
          });

    const totalSeconds = clampNonNegative(args.totalSeconds);
    const notificationBody =
      args.notificationBody?.trim() ||
      buildNotificationBody(args.dayKey, totalSeconds, topApps);

    const timestamp = now();
    const existing = await ctx.db
      .query("intentScreenDays")
      .withIndex("by_owner_day_sourceDevice", (q: any) =>
        q
          .eq("ownerDeviceId", ownerDeviceId)
          .eq("dayKey", args.dayKey)
          .eq("sourceDeviceId", sourceDeviceId),
      )
      .unique();

    await deleteDayChildren(ctx, ownerDeviceId, args.dayKey, sourceDeviceId);

    let dayId: Id<"intentScreenDays">;
    if (existing) {
      await ctx.db.patch(existing._id, {
        source: SCREEN_SOURCE,
        platform: args.platform?.trim() || "iphone",
        totalSeconds,
        eventCount: Math.max(0, Math.floor(args.eventCount)),
        cleanedEventCount: Math.max(0, Math.floor(args.cleanedEventCount)),
        topAppsJson: JSON.stringify(topApps),
        hourlyTotalsJson: JSON.stringify(hourlyTotals),
        notificationBody,
        // re-ingest resets delivery so a revised day can notify again
        notificationDeliveredAt: undefined,
        timeZoneOffsetMinutes: args.timeZoneOffsetMinutes,
        collectedAt: timestamp,
        updatedAt: timestamp,
      });
      dayId = existing._id;
    } else {
      dayId = await ctx.db.insert("intentScreenDays", {
        ownerDeviceId,
        dayKey: args.dayKey,
        source: SCREEN_SOURCE,
        sourceDeviceId,
        platform: args.platform?.trim() || "iphone",
        totalSeconds,
        eventCount: Math.max(0, Math.floor(args.eventCount)),
        cleanedEventCount: Math.max(0, Math.floor(args.cleanedEventCount)),
        topAppsJson: JSON.stringify(topApps),
        hourlyTotalsJson: JSON.stringify(hourlyTotals),
        notificationBody,
        timeZoneOffsetMinutes: args.timeZoneOffsetMinutes,
        collectedAt: timestamp,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    }

    for (const app of apps) {
      await ctx.db.insert("intentScreenAppDays", {
        ownerDeviceId,
        dayKey: args.dayKey,
        sourceDeviceId,
        bundleId: app.bundleId,
        title: app.title,
        seconds: app.seconds,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    }

    for (const hour of hours) {
      await ctx.db.insert("intentScreenHours", {
        ownerDeviceId,
        dayKey: args.dayKey,
        sourceDeviceId,
        hourStartMs: hour.hourStartMs,
        hourOfDay: hour.hourOfDay,
        totalSeconds: hour.totalSeconds,
        topAppsJson: JSON.stringify(hour.topApps),
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    }

    const day = await ctx.db.get(dayId);
    return {
      ok: true,
      day: day ? serializeDay(day, hours) : null,
      cleaning: {
        maxEventSeconds: MAX_EVENT_SECONDS,
        capEventSeconds: CAP_EVENT_SECONDS,
      },
    };
  },
});

export const getScreenSummary = internalQuery({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    dayKey: v.optional(v.string()),
    includeHours: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const device = await authenticateScreenDevice(ctx, args.deviceId, args.deviceSecret);
    if (!device) {
      return null;
    }

    const day = await findScreenDay(ctx, screenOwnerCandidates(args.deviceId), args.dayKey);
    if (!day) {
      return {
        ok: true,
        day: null,
      };
    }

    let hours: Doc<"intentScreenHours">[] | undefined;
    if (args.includeHours !== false) {
      hours = await ctx.db
        .query("intentScreenHours")
        .withIndex("by_owner_day_sourceDevice", (q: any) =>
          q
            .eq("ownerDeviceId", day.ownerDeviceId)
            .eq("dayKey", day.dayKey)
            .eq("sourceDeviceId", day.sourceDeviceId),
        )
        .collect();
      hours.sort((a, b) => a.hourOfDay - b.hourOfDay);
    }

    return {
      ok: true,
      day: serializeDay(
        day,
        hours?.map((hour) => ({
          hourOfDay: hour.hourOfDay,
          hourStartMs: hour.hourStartMs,
          totalSeconds: hour.totalSeconds,
          topApps: parseTopAppsJson(hour.topAppsJson),
        })),
      ),
    };
  },
});

export const listRecentScreenDays = internalQuery({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const device = await authenticateScreenDevice(ctx, args.deviceId, args.deviceSecret);
    if (!device) {
      return null;
    }

    const limit = Math.min(90, Math.max(1, Math.floor(args.limit ?? 21)));
    const byDayKey = new Map<string, Doc<"intentScreenDays">>();

    for (const ownerDeviceId of screenOwnerCandidates(args.deviceId)) {
      const rows = await ctx.db
        .query("intentScreenDays")
        .withIndex("by_owner_collectedAt", (q: any) => q.eq("ownerDeviceId", ownerDeviceId))
        .order("desc")
        .take(limit * 3);
      for (const row of rows) {
        const existing = byDayKey.get(row.dayKey);
        if (!existing || row.collectedAt > existing.collectedAt) {
          byDayKey.set(row.dayKey, row);
        }
      }
    }

    const days = [...byDayKey.values()]
      .sort((a, b) => b.dayKey.localeCompare(a.dayKey))
      .slice(0, limit)
      .map((day) => serializeDay(day));

    return {
      ok: true,
      days,
    };
  },
});

export const ackScreenNotification = internalMutation({
  args: {
    deviceId: v.string(),
    deviceSecret: v.string(),
    dayKey: v.string(),
    sourceDeviceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const device = await authenticateScreenDevice(ctx, args.deviceId, args.deviceSecret);
    if (!device) {
      throw new Error("Invalid device credentials.");
    }

    const day = await findScreenDay(ctx, screenOwnerCandidates(args.deviceId), args.dayKey);
    if (!day) {
      return { ok: false, error: "Day not found." };
    }

    if (args.sourceDeviceId && day.sourceDeviceId !== args.sourceDeviceId) {
      const rows = await ctx.db
        .query("intentScreenDays")
        .withIndex("by_owner_dayKey", (q: any) =>
          q.eq("ownerDeviceId", day.ownerDeviceId).eq("dayKey", args.dayKey),
        )
        .collect();
      const matched =
        rows.find((row) => row.sourceDeviceId === args.sourceDeviceId) ?? day;
      const timestamp = now();
      await ctx.db.patch(matched._id, {
        notificationDeliveredAt: timestamp,
        updatedAt: timestamp,
      });
      return {
        ok: true,
        dayKey: matched.dayKey,
        notificationDeliveredAt: timestamp,
      };
    }

    const timestamp = now();
    await ctx.db.patch(day._id, {
      notificationDeliveredAt: timestamp,
      updatedAt: timestamp,
    });

    return {
      ok: true,
      dayKey: day.dayKey,
      notificationDeliveredAt: timestamp,
    };
  },
});

// keep constants available to http layer docs/tests
export const screenCleaningLimits = {
  maxEventSeconds: MAX_EVENT_SECONDS,
  capEventSeconds: CAP_EVENT_SECONDS,
  topAppsLimit: TOP_APPS_LIMIT,
  source: SCREEN_SOURCE,
  sharedOwnerId: SHARED_SCREEN_OWNER_ID,
};

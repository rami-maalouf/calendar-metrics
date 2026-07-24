import type {
  DailyAggregate,
  DashboardMetricsSummary,
  MetricTimeSeriesPoint,
  RecentActivityItem,
  WeeklyComparison,
} from "@/routes/dashboard";

export type DemoDashboardData = {
  userSettings: {
    selectedCalendarName: string;
  };
  metricsSummary: DashboardMetricsSummary;
  recentActivity: RecentActivityItem[];
  dailyAggregates: DailyAggregate[];
  weeklyComparison: WeeklyComparison;
  metricTimeSeriesByKey: Record<string, MetricTimeSeriesPoint[]>;
};

const NUMERIC_KEYS = [
  "focus",
  "discipline",
  "energy",
  "mindfulness",
  "intentionality",
  "purpose",
  "distractions",
];

const CORE_KEYS = NUMERIC_KEYS.filter((key) => key !== "distractions");

const SESSION_TITLES = [
  "Deep work block",
  "Planning review",
  "Design implementation",
  "Inbox reset",
  "Strategy session",
  "Writing sprint",
  "Code review pass",
  "Research synthesis",
];

const EVENT_TITLES = [
  "Product sync",
  "Customer interview",
  "Roadmap review",
  "Engineering standup",
  "Metrics review",
  "Design critique",
  "Hiring screen",
  "Stakeholder update",
];

const TASK_CATEGORIES = ["Engineering", "Strategy", "Design", "Operations", "Research", "Writing"];
const WORK_MODES = ["Deep work", "Collaboration", "Planning", "Review", "Recovery"];

function seededUnit(seed: number) {
  void seed;
  return Math.random();
}

function choose<T>(items: T[], seed: number): T {
  return items[Math.floor(seededUnit(seed) * items.length) % items.length];
}

function clampScore(value: number) {
  return Math.max(3, Math.min(7, Math.round(value * 10) / 10));
}

function randomBetween(min: number, max: number) {
  return min + Math.random() * (max - min);
}

function dateKey(date: Date) {
  return date.toISOString().slice(0, 10);
}

function startOfUtcDay(date: Date) {
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
}

function average(values: number[]) {
  return Math.round((values.reduce((sum, value) => sum + value, 0) / values.length) * 10) / 10;
}

function addCount(counts: Record<string, number>, value: string) {
  counts[value] = (counts[value] || 0) + 1;
}

function topValue(counts: Record<string, number>) {
  return Object.entries(counts).sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))[0]?.[0] ?? "";
}

export function createDemoDashboardData(now = new Date()): DemoDashboardData {
  const todayMs = startOfUtcDay(now);
  const numericValues: Record<string, number[]> = Object.fromEntries(NUMERIC_KEYS.map((key) => [key, []]));
  const metricTimeSeriesByKey: Record<string, MetricTimeSeriesPoint[]> = Object.fromEntries(
    NUMERIC_KEYS.map((key) => [key, []]),
  );
  const taskCategoryCounts: Record<string, number> = {};
  const workModeCounts: Record<string, number> = {};
  const recentActivity: RecentActivityItem[] = [];
  const dailyAggregates: DailyAggregate[] = [];

  for (let dayIndex = 0; dayIndex < 100; dayIndex++) {
    const daysAgo = 99 - dayIndex;
    const date = new Date(todayMs - daysAgo * 86_400_000);
    const dateStr = dateKey(date);
    const weekday = date.getUTCDay();
    const dayRoll = Math.random();
    const dayProfile =
      dayRoll < 0.22
        ? { base: randomBetween(3.1, 4.2), volatility: randomBetween(0.8, 1.5), activityRate: randomBetween(0.42, 0.68) }
        : dayRoll < 0.48
          ? { base: randomBetween(5.8, 6.7), volatility: randomBetween(0.35, 0.9), activityRate: randomBetween(0.75, 0.96) }
          : { base: randomBetween(4.2, 5.7), volatility: randomBetween(0.5, 1.15), activityRate: randomBetween(0.58, 0.88) };
    const weekdayActivityLift = weekday >= 1 && weekday <= 5 ? 0.08 : -0.1;
    const active = daysAgo <= 2 || Math.random() < dayProfile.activityRate + weekdayActivityLift;
    const dayBuckets: Record<string, number[]> = Object.fromEntries(NUMERIC_KEYS.map((key) => [key, []]));
    let sessionCount = 0;
    let totalHours = 0;

    if (active) {
      const subjectCount = 1 + (Math.random() > 0.62 ? 1 : 0) + (Math.random() > 0.88 ? 1 : 0);

      for (let subjectIndex = 0; subjectIndex < subjectCount; subjectIndex++) {
        const subjectSeed = dayIndex * 17 + subjectIndex * 31;
        const subjectType = seededUnit(subjectSeed + 8) < 0.64 ? "intentSession" : "event";
        const hour = 8 + Math.floor(seededUnit(subjectSeed + 9) * 10);
        const minute = seededUnit(subjectSeed + 10) > 0.5 ? 30 : 0;
        const observedAt = todayMs - daysAgo * 86_400_000 + hour * 3_600_000 + minute * 60_000;
        const titlePrefix = subjectType === "intentSession" ? SESSION_TITLES : EVENT_TITLES;
        const subjectTitle = choose(titlePrefix, subjectSeed + 11);
        const taskCategory = choose(TASK_CATEGORIES, subjectSeed + 12);
        const workMode = choose(WORK_MODES, subjectSeed + 13);
        const dayNoise = randomBetween(-dayProfile.volatility, dayProfile.volatility);
        const swing = Math.random() < 0.16 ? randomBetween(-1.5, 1.2) : 0;
        const hourEffect = hour < 10 ? randomBetween(-0.35, 0.55) : hour < 14 ? randomBetween(-0.7, 0.25) : randomBetween(-0.25, 0.65);
        const base = dayProfile.base + dayNoise + swing + hourEffect;
        const focus = clampScore(base + randomBetween(-0.5, 0.8));
        const discipline = clampScore(base + randomBetween(-0.75, 0.55));
        const energy = clampScore(base + randomBetween(-0.9, 0.75));
        const mindfulness = clampScore(base + randomBetween(-0.8, 0.7));
        const intentionality = clampScore(base + randomBetween(-0.45, 0.65));
        const purpose = clampScore(base + randomBetween(-0.55, 0.75));
        const distractions = clampScore(8.4 - focus + randomBetween(-0.9, 1.1));
        const metrics = {
          focus,
          discipline,
          energy,
          mindfulness,
          intentionality,
          purpose,
          distractions,
        };

        for (const [key, value] of Object.entries(metrics)) {
          numericValues[key].push(value);
          dayBuckets[key].push(value);
          metricTimeSeriesByKey[key].push({
            date: observedAt,
            value,
            subjectTitle,
            subjectType,
          });
        }

        addCount(taskCategoryCounts, taskCategory);
        addCount(workModeCounts, workMode);

        if (subjectType === "intentSession") {
          sessionCount += 1;
          totalHours += 0.75 + seededUnit(subjectSeed + 23) * 1.9;
        }

        recentActivity.push({
          id: `demo:${dateStr}:${subjectIndex}`,
          title: subjectTitle,
          date: observedAt,
          subjectType,
          metrics: [
            { key: "focus", value: focus },
            { key: "energy", value: energy },
            { key: "intentionality", value: intentionality },
            { key: "taskCategory", value: taskCategory },
            { key: "workMode", value: workMode },
          ],
        });
      }
    }

    const avgMetrics = Object.fromEntries(
      Object.entries(dayBuckets)
        .filter(([, values]) => values.length > 0)
        .map(([key, values]) => [key, average(values)]),
    );
    const compositeValues = CORE_KEYS.map((key) => avgMetrics[key]).filter((value): value is number => value !== undefined);

    dailyAggregates.push({
      dateStr,
      sessionCount,
      anyActivity: active,
      totalHours: Math.round(totalHours * 10) / 10,
      avgMetrics,
      compositeScore: compositeValues.length > 0 ? average(compositeValues) : 0,
    });
  }

  const numeric = Object.fromEntries(
    Object.entries(numericValues).map(([key, values]) => [
      key,
      {
        count: values.length,
        avg: average(values),
        min: Math.min(...values),
        max: Math.max(...values),
      },
    ]),
  );
  const sortedActivity = recentActivity.sort((left, right) => right.date - left.date);

  return {
    userSettings: {
      selectedCalendarName: "Demo Work Calendar",
    },
    metricsSummary: {
      numeric,
      categorical: {
        taskCategory: {
          count: Object.values(taskCategoryCounts).reduce((sum, count) => sum + count, 0),
          valueCounts: taskCategoryCounts,
          topValue: topValue(taskCategoryCounts),
        },
        workMode: {
          count: Object.values(workModeCounts).reduce((sum, count) => sum + count, 0),
          valueCounts: workModeCounts,
          topValue: topValue(workModeCounts),
        },
      },
    },
    recentActivity: sortedActivity.slice(0, 8),
    dailyAggregates,
    weeklyComparison: createWeeklyComparison(metricTimeSeriesByKey, todayMs),
    metricTimeSeriesByKey,
  };
}

function createWeeklyComparison(
  metricTimeSeriesByKey: Record<string, MetricTimeSeriesPoint[]>,
  todayMs: number,
): WeeklyComparison {
  const dayOfWeek = new Date(todayMs).getUTCDay();
  const daysToMonday = dayOfWeek === 0 ? 6 : dayOfWeek - 1;
  const thisMondayMs = todayMs - daysToMonday * 86_400_000;
  const lastMondayMs = thisMondayMs - 7 * 86_400_000;

  return {
    thisWeek: averageWindow(metricTimeSeriesByKey, thisMondayMs, todayMs + 86_400_000),
    lastWeek: averageWindow(metricTimeSeriesByKey, lastMondayMs, thisMondayMs),
  };
}

function averageWindow(
  metricTimeSeriesByKey: Record<string, MetricTimeSeriesPoint[]>,
  startMs: number,
  endMs: number,
) {
  return Object.fromEntries(
    Object.entries(metricTimeSeriesByKey)
      .map(([key, points]) => {
        const values = points.filter((point) => point.date >= startMs && point.date < endMs).map((point) => point.value);
        return values.length > 0 ? [key, average(values)] : null;
      })
      .filter((entry): entry is [string, number] => entry !== null),
  );
}

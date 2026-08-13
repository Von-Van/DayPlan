import { addDays, format, parseISO, startOfToday } from "date-fns";

export const localTimeZone =
  Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";

export function isoDay(date: Date) {
  return format(date, "yyyy-MM-dd");
}

export function dayLabel(day: string) {
  return format(parseISO(day), "EEEE, MMMM d");
}

export function dayShort(day: string) {
  return format(parseISO(day), "EEE d");
}

export function todayDay() {
  return isoDay(startOfToday());
}

export function offsetDay(day: string, amount: number) {
  return isoDay(addDays(parseISO(day), amount));
}

export function timeLabel(startAtUtc: string, timeZone = localTimeZone) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(startAtUtc));
}

export function dateTimeFields(startAtUtc: string, timeZone = localTimeZone) {
  const date = new Date(startAtUtc);
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const value = (name: string) =>
    parts.find((part) => part.type === name)?.value ?? "";
  return {
    day: `${value("year")}-${value("month")}-${value("day")}`,
    time: `${value("hour")}:${value("minute")}`,
  };
}

export function localDateTimeToUtc(day: string, time: string) {
  return new Date(`${day}T${time}:00`).toISOString();
}

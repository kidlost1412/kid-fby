import { useState } from "react";
import { DayPicker } from "react-day-picker";
import { vi } from "react-day-picker/locale";
import { format, addDays, addMinutes, startOfDay, isSameDay } from "date-fns";
import clsx from "clsx";
import { CalendarDays, Clock3, TimerOff } from "lucide-react";
import "react-day-picker/style.css";
import { timezoneLabel } from "../locale";

const chipOn = "btn border border-brand-500 bg-brand-50 text-brand-700 ring-1 ring-brand-500";
const chipOff = "btn-secondary";

/** TikTok holds the post and publishes it itself: allowed from 20 minutes to 10 days ahead. */
export const MIN_AHEAD_MINUTES = 20;
export const MAX_AHEAD_DAYS = 10;
export const scheduleBounds = (now = new Date()) => ({ min: addMinutes(now, MIN_AHEAD_MINUTES), max: addDays(now, MAX_AHEAD_DAYS) });
export const inScheduleWindow = (when: Date, now = new Date()) => {
  const { min, max } = scheduleBounds(now);
  return when.getTime() >= min.getTime() - 30_000 && when.getTime() <= max.getTime();
};

export default function SchedulePicker({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const [open, setOpen] = useState(false);
  const selected = value ? new Date(value) : undefined;
  const [time, setTime] = useState("19:00");
  const clock = value ? value.slice(11, 16) : time;
  const choose = (day: Date) => onChange(`${format(day, "yyyy-MM-dd")}T${clock}`);
  const now = new Date();
  const { min, max } = scheduleBounds(now);
  const today = !!selected && isSameDay(selected, now);
  const outside = !!selected && !inScheduleWindow(selected, now);
  const isTomorrow = !!selected && isSameDay(selected, addDays(now, 1));
  const hour = Number(clock.slice(0, 2));
  const onMinDay = !!selected && isSameDay(selected, min);
  const onMaxDay = !!selected && isSameDay(selected, max);
  // A time on the first/last allowed day is only offered when it falls inside the window.
  const hourOff = (h: number) => (onMinDay && h < min.getHours()) || (onMaxDay && h > max.getHours());
  const minuteOff = (m: number) =>
    (onMinDay && hour === min.getHours() && m < min.getMinutes()) || (onMaxDay && hour === max.getHours() && m > max.getMinutes());
  return <div className="rounded-2xl border border-slate-200 bg-slate-50/70 p-4">
    <div className="flex flex-wrap items-center gap-3">
      <button type="button" aria-pressed={!value} className={clsx("min-h-10", !value ? chipOn : chipOff)} onClick={() => { onChange(""); setOpen(false); }}><TimerOff size={16} /> Không hẹn giờ</button>
      <button type="button" aria-pressed={!!value} className={clsx("min-h-10", value ? chipOn : chipOff)} aria-expanded={open} onClick={() => setOpen(!open)}><CalendarDays size={16} />{selected ? format(selected, "dd/MM/yyyy · HH:mm") : "Chọn ngày và giờ"}</button>
      <span className="text-xs text-slate-500">{timezoneLabel()} · giờ 24 tiếng</span>
    </div>
    {outside && <p role="alert" className="mt-3 text-sm text-red-600">Chọn giờ từ {format(min, "HH:mm dd/MM")} đến {format(max, "HH:mm dd/MM")} (20 phút đến 10 ngày tới).</p>}
    {open && <div className="mt-4 flex flex-wrap gap-6 rounded-xl bg-white p-4 ring-1 ring-slate-100" onKeyDown={e => { if (e.key === "Escape") setOpen(false); }}>
      <div className="max-w-full overflow-x-auto"><DayPicker mode="single" required selected={selected} onSelect={day => day && choose(day)} locale={vi} weekStartsOn={1} disabled={[{ before: startOfDay(min) }, { after: startOfDay(max) }]} defaultMonth={selected} showOutsideDays
        labels={{ labelNext: () => "Tháng sau", labelPrevious: () => "Tháng trước", labelNav: () => "Chuyển tháng" }} /></div>
      <div className="min-w-44 flex-1 space-y-4 pt-2">
        <p className="text-sm font-semibold flex items-center gap-2"><Clock3 size={16} /> Giờ đăng video</p>
        <div className="flex items-center gap-2">
          <select aria-label="Giờ đăng" className="input w-20" value={clock.slice(0, 2)} onChange={e => { const next = `${e.target.value}:${clock.slice(3)}`; setTime(next); if (value) onChange(`${value.slice(0, 11)}${next}`); }}>
            {Array.from({ length: 24 }, (_, h) => String(h).padStart(2, "0")).map(h => <option key={h} disabled={hourOff(Number(h))}>{h}</option>)}
          </select><span>:</span>
          <select aria-label="Phút đăng" className="input w-20" value={clock.slice(3)} onChange={e => { const next = `${clock.slice(0, 2)}:${e.target.value}`; setTime(next); if (value) onChange(`${value.slice(0, 11)}${next}`); }}>
            {Array.from({ length: 60 }, (_, m) => String(m).padStart(2, "0")).map(m => <option key={m} disabled={minuteOff(Number(m))}>{m}</option>)}
          </select>
        </div>
        <div className="flex flex-wrap gap-2">
          <button type="button" aria-pressed={today} className={clsx("min-h-10", today ? chipOn : chipOff)} onClick={() => choose(new Date())}>Hôm nay</button>
          <button type="button" aria-pressed={isTomorrow} className={clsx("min-h-10", isTomorrow ? chipOn : chipOff)} onClick={() => choose(addDays(new Date(), 1))}>Ngày mai</button>
        </div>
        <p className="text-xs leading-5 text-slate-500">Hẹn giờ trên TikTok: từ 20 phút đến 10 ngày tới. Video được gửi lên TikTok ngay; TikTok giữ bài và tự đăng đúng giờ. Khi Lịch đăng hiện “Đã hẹn trên TikTok”, bạn có thể tắt máy.</p>
        <button type="button" className="btn-primary" disabled={!value} onClick={() => setOpen(false)}>Xong</button>
      </div>
    </div>}
  </div>;
}

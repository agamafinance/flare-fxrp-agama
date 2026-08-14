'use client';

import { useEffect, useState } from 'react';

// Fixed-rate growth chart, same look as the Starknet price-per-share chart: a header pill,
// a range selector, the big projected value with a dimmed tail, and an area chart. For Flare
// it plots the value of 1 FXRP locked accreting toward its maturity value at the fixed rate.
type Range = 'Live' | '30D' | '90D' | '1Y';
const RANGES: Range[] = ['Live', '30D', '90D', '1Y'];
const DAY = 86400;
const YEAR = 365 * DAY;
const GREEN = '#254839';
const LINE = '#2f5d49';

function niceNum(range: number, round: boolean): number {
  const exp = Math.floor(Math.log10(range || 1));
  const f = (range || 1) / Math.pow(10, exp);
  const nf = round ? (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) : (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10);
  return nf * Math.pow(10, exp);
}
function niceTicks(min: number, max: number, count = 5) {
  if (max - min < 1e-12) {
    const c = min || 1;
    return { ticks: [c * 0.9995, c, c * 1.0005], lo: c * 0.999, hi: c * 1.001, dp: 6 };
  }
  const step = niceNum((max - min) / (count - 1), true);
  const lo = Math.floor(min / step) * step;
  const hi = Math.ceil(max / step) * step;
  const ticks: number[] = [];
  for (let v = lo; v <= hi + step / 2; v += step) ticks.push(Number(v.toFixed(10)));
  const dp = Math.max(0, Math.min(7, -Math.floor(Math.log10(step)) + 1));
  return { ticks, lo, hi, dp };
}
const fmtDate = (t: number) => new Date(t * 1000).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });

export default function FlareChart({ apr, now, maturity }: { apr: number; now: number; maturity: number }) {
  const [range, setRange] = useState<Range>('90D');
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const r = apr / 100;
  const value = (t: number) => Math.pow(1 + r, Math.max(0, t - now) / YEAR); // 1 FXRP -> accreted value
  const term = maturity > now ? maturity - now : 90 * DAY;
  const horizon = Math.min((range === 'Live' ? 1 : range === '30D' ? 30 : range === '90D' ? 90 : 365) * DAY, term) || term;

  const N = 120;
  const vals: number[] = [];
  const xTimes: number[] = [];
  for (let k = 0; k <= N; k++) {
    const t = now + Math.round((k * horizon) / N);
    vals.push(value(t));
    xTimes.push(t);
  }
  const matMultiple = value(maturity);
  const priceStr = matMultiple.toFixed(8);

  const W = 560, H = 300, L = 74, R = 546, T = 16, B = 250;
  const min = Math.min(...vals), max = Math.max(...vals);
  const { ticks, lo, hi, dp } = niceTicks(min, max, 5);
  const xAt = (i: number) => L + (i / (vals.length - 1)) * (R - L);
  const yAt = (v: number) => B - ((v - lo) / (hi - lo || 1)) * (B - T);
  let line = `M ${xAt(0).toFixed(2)} ${yAt(vals[0]).toFixed(2)}`;
  for (let i = 1; i < vals.length; i++) line += ` L ${xAt(i).toFixed(2)} ${yAt(vals[i]).toFixed(2)}`;
  const area = `${line} L ${xAt(vals.length - 1).toFixed(2)} ${B} L ${xAt(0).toFixed(2)} ${B} Z`;

  const xIdx = [0, Math.round((vals.length - 1) / 3), Math.round((2 * (vals.length - 1)) / 3), vals.length - 1];
  const xLabels = xIdx.map((i, k) => ({ x: xAt(i), text: fmtDate(xTimes[i]), anchor: (k === 0 ? 'start' : k === xIdx.length - 1 ? 'end' : 'middle') as 'start' | 'middle' | 'end' }));

  const head = priceStr.slice(0, priceStr.length - 4);
  const dim = priceStr.slice(priceStr.length - 4);
  const days = Math.max(0, Math.ceil((maturity - now) / DAY));

  return (
    <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
      <div className="flex items-center justify-between">
        <span className="rounded-full bg-[#254839]/[0.06] px-3 py-1.5 text-[13px] font-medium text-fg">Fixed-rate growth</span>
        <div className="flex items-center gap-1 rounded-full bg-[#254839]/[0.06] p-1">
          {RANGES.map((rg) => (
            <button key={rg} onClick={() => setRange(rg)}
              className={rg === range ? 'rounded-full bg-[#254839] px-3 py-1 text-[12px] font-medium text-[#fdf8ed]' : 'rounded-full px-3 py-1 text-[12px] text-fg-muted hover:text-fg'}>
              {rg}
            </button>
          ))}
        </div>
      </div>

      <div className="mt-5">
        <div className="text-[12px] uppercase tracking-wider text-fg-muted">1 FXRP locked</div>
        <div className="mt-1 text-[40px] leading-none font-semibold tabular-nums text-fg">
          {head}
          <span className="text-fg-muted/45">{dim}</span>
          <span className="ml-2 text-[16px] font-medium text-fg-muted">FXRP at maturity</span>
        </div>
        <div className="mt-2 text-[13px] text-fg-muted">{apr.toFixed(2)}% fixed · matures in {days} days · locked at deposit</div>
      </div>

      <svg className="mt-4 w-full" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="xMidYMid meet">
        <defs>
          <linearGradient id="flnavfill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={GREEN} stopOpacity="0.16" />
            <stop offset="100%" stopColor={GREEN} stopOpacity="0.01" />
          </linearGradient>
        </defs>
        {ticks.map((tk, i) => {
          const y = yAt(tk);
          if (y < T - 1 || y > B + 1) return null;
          return (
            <g key={i}>
              <line x1={L} y1={y} x2={R} y2={y} stroke={GREEN} strokeOpacity="0.12" strokeDasharray="3 4" strokeWidth="1" />
              <text x={L - 8} y={y + 3.5} fill="#70B19E" fontSize="10" textAnchor="end">{tk.toFixed(dp)}</text>
            </g>
          );
        })}
        {mounted && xLabels.map((xl, i) => (
          <text key={i} x={xl.x} y={B + 20} fill="#70B19E" fontSize="10" textAnchor={xl.anchor}>{xl.text}</text>
        ))}
        <path d={area} fill="url(#flnavfill)" />
        <path d={line} fill="none" stroke={LINE} strokeWidth={2} strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
        <circle cx={xAt(vals.length - 1)} cy={yAt(vals[vals.length - 1])} r={6} fill={LINE} opacity={0.25}>
          <animate attributeName="r" values="4;9;4" dur="1.8s" repeatCount="indefinite" />
          <animate attributeName="opacity" values="0.4;0;0.4" dur="1.8s" repeatCount="indefinite" />
        </circle>
        <circle cx={xAt(vals.length - 1)} cy={yAt(vals[vals.length - 1])} r={3} fill={LINE} />
      </svg>
    </div>
  );
}

import convert from 'color-convert';

export const generateColor = (seed: string, offset: number = 0) => {
  // Simple hash function
  let hash = 0;
  const str = seed.toString() + offset;

  for (let i = 0; i < str.length; i++) {
    hash = str.charCodeAt(i) + ((hash << 5) - hash);
  }

  // Ensure reasonable brightness and saturation
  const h = Math.abs(hash) % 360; // 0-359 hue
  const s = 65 + (Math.abs(hash) % 25); // 65-90% saturation
  const l = 45 + (Math.abs(hash >> 2) % 20); // 45-65% lightness

  return `hsl(${h}, ${s}%, ${l}%)`;
};

/**
 * Convert OKLCH color string to hex
 */
export const oklchToHex = (oklchColor: string): string => {
  const match = oklchColor.match(/oklch\((\d+(?:\.\d+)?)%\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\)/);
  if (!match || !match[1] || !match[2] || !match[3]) return oklchColor;

  const lightness = parseFloat(match[1]);
  const chroma = parseFloat(match[2]);
  const hue = parseFloat(match[3]);

  // Convert OKLCH to LCH (scale chroma from OKLCH 0-0.4 range to LCH 0-100+ range)
  const lch: [number, number, number] = [lightness, chroma * 100, hue];
  const rgb = convert.lch.rgb(lch);
  return `#${rgb.map((x: number) => x.toString(16).padStart(2, '0')).join('')}`;
};

/**
 * Lighten an OKLCH color by a percentage and return as hex
 */
export const lightenColor = (oklchColor: string, percent: number): string => {
  const match = oklchColor.match(/oklch\((\d+(?:\.\d+)?)%\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\)/);
  if (!match || !match[1] || !match[2] || !match[3]) return oklchColor;

  const lightness = parseFloat(match[1]);
  const chroma = parseFloat(match[2]);
  const hue = parseFloat(match[3]);

  const newLightness = Math.min(100, lightness + percent);
  const lch: [number, number, number] = [newLightness, chroma * 100, hue];
  const rgb = convert.lch.rgb(lch);
  return `#${rgb.map((x: number) => x.toString(16).padStart(2, '0')).join('')}`;
};

/**
 * Darken an OKLCH color by a percentage and return as hex
 */
export const darkenColor = (oklchColor: string, percent: number): string => {
  return lightenColor(oklchColor, -percent);
};

// Matches Fizz.Executions.StepExecution @statuses
export type NodeStatus =
  | 'pending'
  | 'queued'
  | 'running'
  | 'completed'
  | 'failed'
  | 'skipped'
  | 'pinned'
  | 'cancelled';

// OKLCH colors inspired by Apache Airflow status colors
export const colorMap: Record<NodeStatus, string> = {
  pending: 'oklch(85% 0.080 240)', // Bright gray - waiting to start
  queued: 'oklch(78% 0.220 240)', // Bright blue - in queue
  running: 'oklch(68% 0.300 230)', // Blue - actively executing
  completed: 'oklch(75% 0.250 140)', // Bright green - finished successfully
  failed: 'oklch(65% 0.300 15)', // Bright red - execution failed
  skipped: 'oklch(70% 0.120 270)', // Bright gray - intentionally skipped
  pinned: 'oklch(62.7% 0.5525 293.477)', // Bright purple - pinned/important node
  cancelled: 'oklch(75% 0.100 0)', // Gray - cancelled
};

// Human-readable labels for UI display
export const statusLabels: Record<NodeStatus, string> = {
  pending: 'Pending',
  queued: 'Queued',
  running: 'Running',
  completed: 'Completed',
  failed: 'Failed',
  skipped: 'Skipped',
  pinned: 'Pinned',
  cancelled: 'Cancelled',
};

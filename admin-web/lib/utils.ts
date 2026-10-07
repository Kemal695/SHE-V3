// =============================================================================
// SHE V3 Admin — Utility functions
// =============================================================================
import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

/** Merge Tailwind CSS class names intelligently */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

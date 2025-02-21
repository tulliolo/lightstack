import { clsx } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs) {
  return twMerge(clsx(inputs))
}

export const getApiUrl = () => {
  if (import.meta.env.PROD) {
    return '/api'
  }
  // In sviluppo, usa la porta 8005
  return 'http://localhost:8005'
}

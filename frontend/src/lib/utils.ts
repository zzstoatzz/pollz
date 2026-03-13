export function ago(dateStr: string): string {
	const ms = Date.now() - new Date(dateStr).getTime();
	const s = Math.floor(ms / 1000);
	if (s < 60) return 'just now';
	const m = Math.floor(s / 60);
	if (m < 60) return `${m}m ago`;
	const h = Math.floor(m / 60);
	if (h < 24) return `${h}h ago`;
	const d = Math.floor(h / 24);
	return `${d}d ago`;
}

export function fullDate(dateStr: string): string {
	return new Date(dateStr).toLocaleString();
}

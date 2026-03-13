const API = import.meta.env.VITE_API_URL ?? 'https://api.pollz.waow.tech';

async function api(path: string, opts?: RequestInit) {
	const res = await fetch(`${API}${path}`, {
		credentials: 'include',
		...opts
	});
	if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
	const text = await res.text();
	if (!text) return null;
	try {
		return JSON.parse(text);
	} catch {
		return null;
	}
}

export type Poll = {
	uri: string;
	repo: string;
	rkey: string;
	text: string;
	options: { text: string; count: number }[];
	createdAt: string;
	author?: { did: string; handle: string; avatar: string | null };
};

export type PollDetail = {
	uri: string;
	repo: string;
	rkey: string;
	text: string;
	options: { text: string; count: number }[];
	createdAt: string;
};

export type Vote = {
	voter: string;
	option: number;
	uri: string;
	createdAt?: string;
	handle?: string;
};

export type User = {
	did: string;
	handle: string;
};

export async function fetchPolls(): Promise<Poll[]> {
	return api('/api/polls');
}

export async function fetchPoll(uri: string): Promise<PollDetail | null> {
	try {
		return await api(`/api/polls/${encodeURIComponent(uri)}`);
	} catch {
		return null;
	}
}

export async function fetchVotes(pollUri: string): Promise<Vote[]> {
	return api(`/api/polls/${encodeURIComponent(pollUri)}/votes`);
}

export async function createPoll(text: string, options: string[]) {
	return api('/api/polls', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ text, options })
	});
}

export async function deletePoll(pollUri: string) {
	return api(`/api/polls/${encodeURIComponent(pollUri)}`, { method: 'DELETE' });
}

export async function vote(pollUri: string, option: number) {
	return api(`/api/polls/${encodeURIComponent(pollUri)}/vote`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ subject: pollUri, option })
	});
}

export async function getMe(): Promise<User | null> {
	try {
		return await api('/api/me');
	} catch {
		return null;
	}
}

export async function logout() {
	await api('/api/logout', { method: 'POST' });
}

export function loginUrl(handle: string): string {
	return `${API}/oauth/login?handle=${encodeURIComponent(handle)}`;
}

import { getMe, type User } from './api';

let user = $state<User | null>(null);
let loaded = $state(false);

export function getUser() {
	return user;
}

export function isLoaded() {
	return loaded;
}

export function setUser(u: User | null) {
	user = u;
}

export async function loadUser() {
	user = await getMe();
	loaded = true;
}

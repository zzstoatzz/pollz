<script lang="ts">
	import '../app.css';
	import { loadUser, getUser, setUser, isLoaded } from '$lib/user.svelte';
	import { logout as apiLogout, loginUrl } from '$lib/api';
	import { onMount } from 'svelte';

	let { children } = $props();

	let handle = $state('');

	onMount(() => {
		loadUser();
	});

	function doLogout() {
		apiLogout().then(() => setUser(null));
	}

	function doLogin() {
		if (handle.trim()) {
			window.location.href = loginUrl(handle.trim());
		}
	}
</script>

<header>
	<div class="left">
		<a href="/">pollz</a>
		<a href="https://tangled.sh/@zzstoatzz.io/pollz" class="src">[src]</a>
	</div>
	<nav>
		{#if isLoaded()}
			{#if getUser()}
				<a href="/">all</a>
				<a href="/mine">mine</a>
				<a href="/new">new</a>
				<button onclick={doLogout}>logout</button>
			{:else}
				<input
					type="text"
					placeholder="handle"
					bind:value={handle}
					onkeydown={(e) => e.key === 'Enter' && doLogin()}
				/>
				<button onclick={doLogin}>login</button>
			{/if}
		{/if}
	</nav>
</header>

{@render children()}

<style>
	header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding-bottom: 0.75rem;
		margin-bottom: 1rem;
		border-bottom: 1px solid #222;
	}

	.left {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}

	.left a:first-child {
		font-weight: bold;
		color: #ccc;
	}

	.src {
		font-size: 0.75em;
		color: #555;
	}

	nav {
		display: flex;
		align-items: center;
		gap: 0.75rem;
	}

	nav input {
		width: 140px;
		padding: 0.25rem 0.4rem;
		font-size: 13px;
	}

	nav button {
		padding: 0.25rem 0.5rem;
		font-size: 13px;
	}
</style>

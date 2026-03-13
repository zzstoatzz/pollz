<script module lang="ts">
	import type { Vote } from '$lib/api';

	const votesCache = new Map<string, Vote[]>();

	export function invalidateVotesCache(pollUri: string) {
		votesCache.delete(pollUri);
	}
</script>

<script lang="ts">
	import { fetchVotes } from '$lib/api';
	import type { Snippet } from 'svelte';

	let {
		pollUri,
		options,
		children
	}: {
		pollUri: string;
		options: { text: string; count: number }[];
		children: Snippet;
	} = $props();

	let visible = $state(false);
	let votes = $state<Vote[]>([]);
	let loading = $state(false);
	let timer: ReturnType<typeof setTimeout> | undefined = undefined;

	const grouped = $derived(
		votes.reduce<Record<number, Vote[]>>((acc, v) => {
			(acc[v.option] ??= []).push(v);
			return acc;
		}, {})
	);

	function formatVoter(v: Vote): string {
		if (v.handle) return `@${v.handle}`;
		const did = v.voter;
		if (did.length > 24) return did.slice(0, 20) + '...';
		return did;
	}

	async function loadVotes() {
		if (votesCache.has(pollUri)) {
			votes = votesCache.get(pollUri)!;
			return;
		}
		loading = true;
		try {
			const result = await fetchVotes(pollUri);
			votesCache.set(pollUri, result);
			votes = result;
		} catch (e) {
			console.error('failed to fetch votes', e);
			votes = [];
		} finally {
			loading = false;
		}
	}

	async function show() {
		timer = setTimeout(async () => {
			visible = true;
			await loadVotes();
		}, 150);
	}

	function hide() {
		clearTimeout(timer);
		timer = undefined;
		visible = false;
		document.removeEventListener('click', closeOnOutsideClick);
	}

	function toggle(e: MouseEvent) {
		e.stopPropagation();
		if (visible) {
			hide();
			return;
		}
		visible = true;
		loadVotes();
		document.addEventListener('click', closeOnOutsideClick, { once: true });
	}

	function closeOnOutsideClick() {
		hide();
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions a11y_click_events_have_key_events -->
<span
	class="tooltip-wrapper"
	onmouseenter={show}
	onmouseleave={hide}
	onfocusin={show}
	onfocusout={hide}
	onclick={toggle}
>
	{@render children()}

	{#if visible}
		<div class="tooltip">
			{#if loading}
				<span class="entry">loading...</span>
			{:else if votes.length === 0}
				<span class="entry">no votes yet</span>
			{:else}
				{#each options as option, i (i)}
					{@const optionVotes = grouped[i] ?? []}
					{#if optionVotes.length > 0}
						<div class="option-group">
							<div class="option-label">{option.text}</div>
							{#each optionVotes as v (v.uri)}
								<div class="entry">
									{#if v.handle}
										<a href="https://bsky.app/profile/{v.handle}" class="handle" target="_blank" rel="noopener">@{v.handle}</a>
									{:else}
										<span class="handle">{formatVoter(v)}</span>
									{/if}
								</div>
							{/each}
						</div>
					{/if}
				{/each}
			{/if}
		</div>
	{/if}
</span>

<style>
	.tooltip-wrapper {
		position: relative;
		display: inline-block;
	}

	.tooltip {
		position: absolute;
		top: 100%;
		left: 0;
		z-index: 10;
		background: #1a1a1a;
		border: 1px solid #333;
		padding: 0.5rem;
		font-family: monospace;
		font-size: 12px;
		max-height: 200px;
		overflow-y: auto;
		min-width: 180px;
		white-space: nowrap;
	}

	.option-group {
		margin-bottom: 0.25rem;
	}

	.option-label {
		color: #666;
		font-size: 11px;
		margin-bottom: 2px;
	}

	.entry {
		color: #999;
		line-height: 1.6;
	}

	.handle {
		color: #aaa;
		text-decoration: none;
	}

	a.handle:hover {
		color: #ddd;
	}
</style>

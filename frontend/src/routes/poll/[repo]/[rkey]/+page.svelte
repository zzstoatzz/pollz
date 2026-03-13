<script lang="ts">
	import { fetchPoll, vote as apiVote, deletePoll, type PollDetail } from '$lib/api';
	import { ago, fullDate } from '$lib/utils';
	import { getUser } from '$lib/user.svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';
	import VotersTooltip, { invalidateVotesCache } from '$lib/components/VotersTooltip.svelte';

	let poll = $state<PollDetail | null>(null);
	let loading = $state(true);
	let voting = $state(false);
	let status = $state('');

	const repo = $derived(page.params.repo);
	const rkey = $derived(page.params.rkey);
	const uri = $derived(`at://${repo}/tech.waow.pollz.poll/${rkey}`);

	const totalVotes = $derived(
		poll ? poll.options.reduce((sum, o) => sum + o.count, 0) : 0
	);

	const isOwner = $derived(() => {
		const user = getUser();
		return !!user && repo === user.did;
	});

	async function loadPoll() {
		poll = await fetchPoll(uri);
	}

	onMount(async () => {
		try {
			await loadPoll();
		} catch (e) {
			console.error('failed to load poll', e);
		} finally {
			loading = false;
		}
	});

	async function handleDelete() {
		if (!confirm('delete this poll?')) return;
		status = 'deleting...';
		try {
			await deletePoll(uri);
			goto('/');
		} catch (e) {
			status = e instanceof Error ? e.message : 'failed to delete';
			setTimeout(() => (status = ''), 3000);
		}
	}

	async function handleVote(optionIndex: number) {
		if (!getUser()) {
			status = 'login to vote';
			setTimeout(() => (status = ''), 2000);
			return;
		}
		if (!poll) return;
		voting = true;
		status = 'voting...';
		try {
			await apiVote(uri, optionIndex);

			const beforeCounts = poll.options.map((o) => o.count);
			let confirmed = false;
			for (let i = 0; i < 10; i++) {
				await new Promise((r) => setTimeout(r, 500));
				await loadPoll();
				if (poll && poll.options.some((o, j) => o.count !== beforeCounts[j])) {
					confirmed = true;
					break;
				}
			}
			if (confirmed) {
				invalidateVotesCache(uri);
				status = 'voted';
				setTimeout(() => (status = ''), 2000);
			} else {
				status = 'vote may still be processing';
				setTimeout(() => (status = ''), 3000);
			}
		} catch (e) {
			status = e instanceof Error ? e.message : 'failed to vote';
			setTimeout(() => (status = ''), 3000);
		} finally {
			voting = false;
		}
	}

	function copyLink() {
		navigator.clipboard.writeText(window.location.href);
		status = 'link copied';
		setTimeout(() => (status = ''), 1500);
	}
</script>

<div class="poll-detail">
	<a href="/" class="back">&larr; all polls</a>

	{#if loading}
		<p class="status-msg">loading...</p>
	{:else if !poll}
		<p class="status-msg">poll not found</p>
	{:else}
		<div class="poll-header">
			<h2>{poll.text}</h2>
			<div class="header-actions">
				{#if isOwner()}
					<button class="delete-btn" onclick={handleDelete}>delete</button>
				{/if}
				<button class="share-btn" onclick={copyLink}>copy link</button>
			</div>
		</div>

		<div class="options">
			{#each poll.options as option, i (i)}
				{@const pct = totalVotes > 0 ? Math.round((option.count / totalVotes) * 100) : 0}
				<button
					class="option"
					disabled={voting}
					onclick={() => handleVote(i)}
				>
					<div class="option-bar" style="width: {pct}%"></div>
					<span class="option-text">{option.text}</span>
					<span class="option-count">{option.count} ({pct}%)</span>
				</button>
			{/each}
		</div>

		<div class="poll-meta">
			<span title={fullDate(poll.createdAt)}>{ago(poll.createdAt)}</span> &middot;
			<VotersTooltip pollUri={poll.uri} options={poll.options}>
				<span class="vote-count">{totalVotes} vote{totalVotes === 1 ? '' : 's'}</span>
			</VotersTooltip>
		</div>
	{/if}

	{#if status}
		<p class="status-msg">{status}</p>
	{/if}
</div>

<style>
	.poll-detail {
		max-width: 600px;
	}

	.back {
		color: #555;
		font-size: 13px;
		display: inline-block;
		margin-bottom: 1rem;
	}

	.back:hover {
		color: #888;
	}

	h2 {
		margin: 0;
		font-size: 18px;
		font-weight: normal;
	}

	.status-msg {
		color: #888;
		font-size: 13px;
		margin-top: 0.5rem;
	}

	.poll-detail .options {
		margin-top: 0.5rem;
	}

	.poll-detail .option {
		position: relative;
		display: flex;
		align-items: center;
		width: 100%;
		padding: 0.75rem;
		margin: 0.5rem 0;
		background: #111;
		border: 1px solid #222;
		cursor: pointer;
		color: #ccc;
		font-family: monospace;
		font-size: 14px;
		text-align: left;
		min-height: 44px;
		-webkit-tap-highlight-color: transparent;
	}

	.poll-detail .option:hover {
		border-color: #444;
	}

	.poll-detail .option:disabled {
		cursor: wait;
		opacity: 0.7;
	}

	.option-bar {
		position: absolute;
		left: 0;
		top: 0;
		height: 100%;
		background: #1a3a1a;
		z-index: 0;
		transition: width 0.3s;
	}

	.option-text,
	.option-count {
		position: relative;
		z-index: 1;
	}

	.option-count {
		color: #888;
		font-size: 12px;
		margin-left: 1rem;
	}

	.poll-meta {
		color: #555;
		font-size: 12px;
		margin-top: 1rem;
	}

	.vote-count {
		cursor: default;
		border-bottom: 1px dotted #444;
	}

	.poll-header {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
		gap: 1rem;
		margin-bottom: 1rem;
	}

	.header-actions {
		display: flex;
		gap: 0.5rem;
	}

	.share-btn,
	.delete-btn {
		background: none;
		border: 1px solid #333;
		color: #888;
		padding: 0.4rem 0.8rem;
		font-family: monospace;
		font-size: 12px;
		cursor: pointer;
	}

	.share-btn:hover {
		border-color: #555;
		color: #ccc;
	}

	.delete-btn:hover {
		border-color: #733;
		color: #c44;
	}
</style>

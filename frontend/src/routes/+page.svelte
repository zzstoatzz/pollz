<script lang="ts">
	import { fetchPolls, vote as apiVote, fetchPoll, deletePoll, type Poll } from '$lib/api';
	import { ago, fullDate } from '$lib/utils';
	import { getUser } from '$lib/user.svelte';
	import { onMount } from 'svelte';
	import VotersTooltip, { invalidateVotesCache } from '$lib/components/VotersTooltip.svelte';

	let polls = $state<Poll[]>([]);
	let loading = $state(true);
	let votingUri = $state<string | null>(null);
	let statusMap: Record<string, string> = $state({});

	onMount(async () => {
		try {
			const data = await fetchPolls();
			polls = data.sort(
				(a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
			);
		} catch (e) {
			console.error('failed to fetch polls', e);
		} finally {
			loading = false;
		}
	});

	function totalVotes(poll: Poll): number {
		return poll.options.reduce((sum, o) => sum + o.count, 0);
	}

	function pct(count: number, total: number): number {
		return total > 0 ? Math.round((count / total) * 100) : 0;
	}

	function setStatus(uri: string, msg: string, duration: number) {
		statusMap[uri] = msg;
		setTimeout(() => {
			if (statusMap[uri] === msg) statusMap[uri] = '';
		}, duration);
	}

	function isOwner(poll: Poll): boolean {
		const user = getUser();
		return !!user && poll.repo === user.did;
	}

	async function handleDelete(poll: Poll) {
		if (!confirm('delete this poll?')) return;
		setStatus(poll.uri, 'deleting...', 10000);
		try {
			await deletePoll(poll.uri);
			polls = polls.filter((p) => p.uri !== poll.uri);
		} catch (e) {
			console.error('delete failed', e);
			setStatus(poll.uri, 'failed to delete', 3000);
		}
	}

	async function handleVote(poll: Poll, optionIndex: number) {
		if (!getUser()) return;
		if (votingUri) return;

		votingUri = poll.uri;
		setStatus(poll.uri, 'voting...', 10000);
		try {
			await apiVote(poll.uri, optionIndex);

			const beforeCounts = poll.options.map((o) => o.count);
			let confirmed = false;
			for (let i = 0; i < 10; i++) {
				await new Promise((r) => setTimeout(r, 500));
				const fresh = await fetchPoll(poll.uri);
				if (fresh && fresh.options.some((o, j) => o.count !== beforeCounts[j])) {
					const idx = polls.findIndex((p) => p.uri === poll.uri);
					if (idx !== -1) {
						polls[idx] = { ...polls[idx], options: fresh.options };
					}
					confirmed = true;
					break;
				}
			}
			if (confirmed) {
				invalidateVotesCache(poll.uri);
				setStatus(poll.uri, 'voted', 2000);
			} else {
				setStatus(poll.uri, 'vote may still be processing', 3000);
			}
		} catch (e) {
			console.error('vote failed', e);
			setStatus(poll.uri, 'failed to vote', 3000);
		} finally {
			votingUri = null;
		}
	}
</script>

{#if getUser()}
	<a href="/new" class="new-poll">+ new poll</a>
{/if}

{#if loading}
	<p class="status">loading polls...</p>
{:else if polls.length === 0}
	<p class="status">no polls yet</p>
{:else}
	{#each polls as poll (poll.uri)}
		{@const total = totalVotes(poll)}
		<div class="poll">
			<div class="poll-header">
				{#if poll.author}
					<div class="poll-author">
						{#if poll.author.avatar}
							<img
								src={poll.author.avatar}
								alt=""
								class="avatar"
							/>
						{:else}
							<div class="avatar avatar-placeholder"></div>
						{/if}
						<a href="https://bsky.app/profile/{poll.author.handle}" class="handle" target="_blank" rel="noopener">@{poll.author.handle}</a>
					</div>
				{/if}
				<a href="/poll/{poll.repo}/{poll.rkey}" class="poll-question">{poll.text}</a>
			</div>

			<div class="options">
				{#each poll.options as option, i (i)}
					{@const p = pct(option.count, total)}
					<button
						class="option"
						disabled={votingUri === poll.uri || !getUser()}
						onclick={() => handleVote(poll, i)}
					>
						<div class="option-bar" style="width: {p}%"></div>
						<span class="option-text">{option.text}</span>
						<span class="option-count">{option.count} ({p}%)</span>
					</button>
				{/each}
			</div>

			<div class="poll-meta">
				<span title={fullDate(poll.createdAt)}>{ago(poll.createdAt)}</span> &middot;
				<VotersTooltip pollUri={poll.uri} options={poll.options}>
					<span class="vote-count">{total} {total === 1 ? 'vote' : 'votes'}</span>
				</VotersTooltip>
				{#if isOwner(poll)}
					&middot; <button class="delete-btn" onclick={() => handleDelete(poll)}>delete</button>
				{/if}
				{#if statusMap[poll.uri]}
					<span class="inline-status"> &middot; {statusMap[poll.uri]}</span>
				{/if}
			</div>
		</div>
	{/each}
{/if}

<style>
	.new-poll {
		display: inline-block;
		margin-bottom: 1rem;
		color: #888;
	}

	.new-poll:hover {
		color: #ccc;
	}

	.status {
		color: #555;
	}

	.poll {
		border-bottom: 1px solid #222;
		padding: 1rem 0;
	}

	.poll-header {
		margin-bottom: 0.5rem;
	}

	.poll-author {
		display: flex;
		align-items: center;
		gap: 0.4rem;
		margin-bottom: 0.35rem;
	}

	.avatar {
		width: 20px;
		height: 20px;
		border-radius: 50%;
		object-fit: cover;
	}

	.avatar-placeholder {
		background: #333;
	}

	.handle {
		color: #555;
		font-size: 12px;
		text-decoration: none;
	}

	.handle:hover {
		color: #888;
	}

	.poll-question {
		color: #fff;
		display: block;
		font-size: 15px;
	}

	.poll-question:hover {
		color: #ccc;
	}

	.options {
		margin-top: 0.5rem;
	}

	.option {
		position: relative;
		display: flex;
		align-items: center;
		width: 100%;
		padding: 0.5rem 0.75rem;
		margin: 0.35rem 0;
		background: #111;
		border: 1px solid #222;
		cursor: pointer;
		color: #ccc;
		font-family: monospace;
		font-size: 13px;
		text-align: left;
		min-height: 44px;
		-webkit-tap-highlight-color: transparent;
	}

	.option:hover:not(:disabled) {
		border-color: #444;
	}

	.option:disabled {
		cursor: default;
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
		font-size: 11px;
		margin-left: auto;
		padding-left: 0.5rem;
		white-space: nowrap;
	}

	.poll-meta {
		color: #555;
		font-size: 12px;
		margin-top: 0.5rem;
	}

	.vote-count {
		cursor: default;
		border-bottom: 1px dotted #444;
	}

	.delete-btn {
		background: none;
		border: none;
		color: #555;
		font-family: monospace;
		font-size: 12px;
		cursor: pointer;
		padding: 0;
	}

	.delete-btn:hover {
		color: #c44;
	}

	.inline-status {
		color: #888;
	}
</style>

<script lang="ts">
	import { fetchPolls, type Poll } from '$lib/api';
	import { ago, fullDate } from '$lib/utils';
	import { getUser } from '$lib/user.svelte';
	import { onMount } from 'svelte';

	let polls = $state<Poll[]>([]);
	let loading = $state(true);

	onMount(async () => {
		const user = getUser();
		if (!user) {
			loading = false;
			return;
		}
		try {
			const all = await fetchPolls();
			polls = all
				.filter((p) => p.repo === user.did)
				.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
		} finally {
			loading = false;
		}
	});
</script>

{#if !getUser()}
	<p class="empty">login to see your polls</p>
{:else if loading}
	<p class="empty">loading...</p>
{:else if polls.length === 0}
	<p class="empty">you haven't created any polls yet</p>
{:else}
	<ul>
		{#each polls as poll (poll.uri)}
			{@const total = poll.options.reduce((s, o) => s + o.count, 0)}
			<li>
				<a href="/poll/{poll.repo}/{poll.rkey}">
					<span class="text">{poll.text}</span>
					<span class="meta">
						{poll.options.length} options &middot; {total} {total === 1 ? 'vote' : 'votes'} &middot; <span title={fullDate(poll.createdAt)}>{ago(poll.createdAt)}</span>
					</span>
				</a>
			</li>
		{/each}
	</ul>
{/if}

<style>
	.empty {
		color: #555;
		margin-top: 2rem;
		text-align: center;
	}

	ul {
		list-style: none;
	}

	li {
		border: 1px solid #222;
		margin-bottom: 0.5rem;
	}

	li a {
		display: block;
		padding: 0.75rem;
		color: #ccc;
		text-decoration: none;
	}

	li a:hover {
		background: #151515;
	}

	.text {
		display: block;
		margin-bottom: 0.25rem;
	}

	.meta {
		font-size: 0.8em;
		color: #555;
	}
</style>

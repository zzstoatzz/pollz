<script lang="ts">
	import { createPoll } from '$lib/api';
	import { getUser } from '$lib/user.svelte';
	import { goto } from '$app/navigation';

	let question = $state('');
	let optionsText = $state('');
	let status = $state('');

	async function submit() {
		const text = question.trim();
		const options = optionsText
			.split('\n')
			.map((o) => o.trim())
			.filter(Boolean);

		if (!text || options.length < 2) {
			status = 'need a question and at least 2 options';
			return;
		}

		status = 'creating...';
		try {
			await createPoll(text, options);
			goto('/');
		} catch (e) {
			status = e instanceof Error ? e.message : 'failed to create poll';
		}
	}
</script>

{#if !getUser()}
	<p>login to create</p>
{:else}
	<form class="create-form" onsubmit={(e) => { e.preventDefault(); submit(); }}>
		<input type="text" placeholder="question" bind:value={question} />
		<textarea placeholder="options (one per line)" rows={4} bind:value={optionsText}></textarea>
		<button type="submit">create</button>
		{#if status}
			<p class="status">{status}</p>
		{/if}
	</form>
{/if}

<style>
	.create-form input,
	.create-form textarea {
		width: 100%;
		margin-bottom: 0.5rem;
	}

	.status {
		color: #666;
	}
</style>

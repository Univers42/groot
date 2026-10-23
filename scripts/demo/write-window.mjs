// write-window.mjs — when the Arlet seed may write to baas. scripts/demo/vm/lib.sh
// write_window_reason is the VM's copy; tests/demo-seed/vm-bootstrap.bats proves the two agree
// for every minute of the day. :58-:07 is b2b-backup's hourly pg_dump, 00:30-00:50 b2b-var-gc.

export function windowReason(hour, minute) {
	const resume = (h) => `${String(h).padStart(2, '0')}:08`;
	if (minute >= 58) return `b2b-backup's hourly pg_dump; writing resumes at ${resume((hour + 1) % 24)}`;
	if (minute <= 7) return `b2b-backup's hourly pg_dump; writing resumes at ${resume(hour)}`;
	if (hour === 0 && minute >= 30 && minute <= 50) return 'b2b-var-gc; writing resumes at 00:51';
	return '';
}

// localClock(date, offset) — [hour, minute] at a `date +%z` offset such as +0200. The tools
// container runs in UTC, so getHours() alone put the 00:30 gc window two hours late.
export function localClock(date, offset) {
	if (!/^[+-]\d{4}$/.test(offset ?? '')) throw new Error(`utc offset '${offset}' is not like +0200`);
	const sign = offset.startsWith('-') ? -1 : 1;
	const minutes = sign * (Number(offset.slice(1, 3)) * 60 + Number(offset.slice(3, 5)));
	const shifted = new Date(date.getTime() + minutes * 60_000);
	return [shifted.getUTCHours(), shifted.getUTCMinutes()];
}

if (import.meta.url === `file://${process.argv[1]}`) {
	for (let hour = 0; hour < 24; hour += 1) {
		for (let minute = 0; minute < 60; minute += 1) process.stdout.write(`${hour} ${minute} ${windowReason(hour, minute)}\n`);
	}
}

/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   box-init.c                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/14 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/14 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

/*
** PID 1 of an IDE box. It reaps every orphan reparented to it, and unlike tini
** it never exits on its own. With tini, `kill 1`, `pkill -x sleep` or
** `kill -9 -1` from inside the box stopped the whole box, because tini exits
** when its child dies (devil s45t, condition 1). With `sleep infinity` as PID 1
** nothing reaped: hellish's `make -j8` left 469 zombies and every fork failed.
** A namespace init with no handler loses every signal sent from inside, and
** from outside only SIGKILL reaches it, so `docker stop` runs its timeout and
** then SIGKILL, as it did with `sleep infinity`. Blocking signals instead keeps
** them queued: a box user filled the uid's sigpending limit, 4096/4096, through
** PID 1 (devil s45t advisory).
** Ponytail: with no child left it polls once a second, so an orphan can stay a
** zombie for up to 1 s; the Cmd is started once and never restarted.
**
** It also writes the box's default /tmp/.osio/passwd (a copy of /etc/passwd.base, which names
** the user coder, with the coder line's uid replaced by getuid(): each user's box runs as its own
** uid, ADR 0011) before the Cmd starts: /etc/passwd is a symlink to that file, and without it
** the first `docker exec` could not resolve the numeric user's home. The write is never fatal.
** Caveat: the Cmd is forked right after, so a `docker exec` that lands in the first
** milliseconds can still see no file (runc then resolves no home, HOME comes from the create
** Env, and `whoami` answers "I have no name!"); osio-login writes the file again on every
** terminal, and a box restart rebuilds it.
*/

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define PASSWD_BASE "/etc/passwd.base"
#define PASSWD_DIR "/tmp/.osio"
#define PASSWD_TMP "/tmp/.osio/passwd.init"
#define PASSWD_FILE "/tmp/.osio/passwd"
#define PASSWD_MAX 16384
#define CODER_BASE "coder:x:10001:10001:"

static ssize_t	read_base(char *buf, size_t size)
{
	ssize_t	len;
	int		in;

	in = open(PASSWD_BASE, O_RDONLY);
	if (in < 0)
		return (-1);
	len = read(in, buf, size);
	close(in);
	if (len <= 0 || len == (ssize_t)size)
		return (-1);
	return (len);
}

/* The coder line, at the start of the file or of a line, or NULL. */
static char	*find_coder(char *buf, ssize_t len)
{
	char	*at;

	buf[len] = '\0';
	at = strstr(buf, CODER_BASE);
	while (at != NULL && at != buf && at[-1] != '\n')
		at = strstr(at + 1, CODER_BASE);
	return (at);
}

static int	copy_base(int out)
{
	static char	buf[PASSWD_MAX + 1];
	char		line[64];
	ssize_t		len;
	char		*at;
	int			head;

	len = read_base(buf, PASSWD_MAX);
	at = len < 0 ? NULL : find_coder(buf, len);
	if (at == NULL)
		return (-1);
	head = snprintf(line, sizeof(line), "coder:x:%u:10001:", (unsigned)getuid());
	if (head <= 0 || write(out, buf, (size_t)(at - buf)) != at - buf)
		return (-1);
	if (write(out, line, (size_t)head) != head)
		return (-1);
	at += strlen(CODER_BASE);
	return (write(out, at, (size_t)(buf + len - at)) == buf + len - at ? 0 : -1);
}

static void	write_default_passwd(void)
{
	int	out;
	int	done;

	if (mkdir(PASSWD_DIR, 0755) < 0 && errno != EEXIST)
		return ;
	out = open(PASSWD_TMP, O_WRONLY | O_CREAT | O_EXCL, 0644);
	if (out < 0)
		return ;
	done = copy_base(out) == 0;
	if (close(out) < 0)
		done = 0;
	if (!done || rename(PASSWD_TMP, PASSWD_FILE) < 0)
		unlink(PASSWD_TMP);
}

int	main(int argc, char **argv)
{
	write_default_passwd();
	if (argc > 1 && fork() == 0)
	{
		execvp(argv[1], argv + 1);
		_exit(127);
	}
	while (1)
	{
		if (wait(NULL) < 0 && errno == ECHILD)
			sleep(1);
	}
}

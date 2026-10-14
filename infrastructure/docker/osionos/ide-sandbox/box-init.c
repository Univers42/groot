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
*/

#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>

int	main(int argc, char **argv)
{
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

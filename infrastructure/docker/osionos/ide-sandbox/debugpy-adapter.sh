#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    debugpy-adapter.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# debugpy-adapter — the Python debug adapter (DAP) on stdio, for the IDE's debug relay.
# debugpy lives in /opt/debugpy, outside site-packages, so a user's own `pip install
# debugpy` in the workspace cannot replace the reviewed copy. stdout IS the DAP stream.
PYTHONPATH=/opt/debugpy
export PYTHONPATH
exec python3 -m debugpy.adapter

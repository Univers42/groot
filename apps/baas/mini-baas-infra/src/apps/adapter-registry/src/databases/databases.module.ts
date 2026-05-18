/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   databases.module.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { DatabasesController } from './databases.controller';
import { DatabasesService } from './databases.service';

@Module({
  imports: [ConfigModule],
  controllers: [DatabasesController],
  providers: [DatabasesService],
})
export class DatabasesModule {}

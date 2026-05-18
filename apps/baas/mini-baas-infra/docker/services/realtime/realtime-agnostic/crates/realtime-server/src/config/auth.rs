/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Authentication configuration.

use serde::{Deserialize, Serialize};

/// Authentication backend selection.
///
/// - `NoAuth` — accepts all tokens (development only).
/// - `Jwt` — validates HMAC-SHA256 / RSA tokens.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AuthConfig {
    #[serde(rename = "none")]
    #[default]
    NoAuth,
    #[serde(rename = "jwt")]
    Jwt {
        secret: String,
        #[serde(default)]
        issuer: Option<String>,
        #[serde(default)]
        audience: Option<String>,
    },
}

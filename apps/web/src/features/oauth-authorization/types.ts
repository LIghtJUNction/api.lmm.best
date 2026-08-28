/*
Copyright (C) 2026 LIghtJUNction

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/
export type OAuthAuthorizationPreview = {
  client_id: string
  client_name: string
  redirect_uri: string
  scopes: string[]
  expires_at: string
}

export type OAuthAuthorizationDecision = {
  redirect_uri: string
}

export type OAuthDeviceDecision = {
  approved: boolean
}

export type OAuthScope =
  | 'api_keys:list'
  | 'api_keys:create'
  | 'api_keys:reveal'
  | 'cc_switch:import'

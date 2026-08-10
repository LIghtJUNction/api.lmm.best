/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import type { FileUIPart } from 'ai'

import type { PlaygroundAttachment, PlaygroundSubmission } from '../../types'

export const PLAYGROUND_ATTACHMENT_ACCEPT = [
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
  'image/avif',
  'text/plain',
  'text/markdown',
  'text/csv',
  'text/xml',
  'application/json',
  'application/xml',
  '.txt',
  '.md',
  '.markdown',
  '.csv',
  '.json',
  '.yaml',
  '.yml',
  '.xml',
  '.html',
  '.css',
  '.js',
  '.jsx',
  '.ts',
  '.tsx',
  '.py',
  '.go',
  '.rs',
  '.sh',
].join(',')

export const PLAYGROUND_MAX_FILES = 4
export const PLAYGROUND_MAX_FILE_BYTES = 5 * 1024 * 1024
const MAX_TEXT_ATTACHMENT_CHARACTERS = 100_000

const TEXT_MEDIA_TYPES = new Set([
  'application/json',
  'application/xml',
  'application/yaml',
  'application/x-yaml',
])
const TEXT_FILE_EXTENSIONS = new Set([
  'txt',
  'md',
  'markdown',
  'csv',
  'json',
  'yaml',
  'yml',
  'xml',
  'html',
  'css',
  'js',
  'jsx',
  'ts',
  'tsx',
  'py',
  'go',
  'rs',
  'sh',
])

function normalizedFilename(filename?: string): string {
  const value = filename?.replaceAll(/[\r\n\t]/g, ' ').trim()
  return value?.slice(0, 180) || 'attachment'
}

function extensionOf(filename: string): string {
  const index = filename.lastIndexOf('.')
  return index >= 0 ? filename.slice(index + 1).toLowerCase() : ''
}

function isTextAttachment(file: FileUIPart): boolean {
  const mediaType = file.mediaType?.toLowerCase() || ''
  return (
    mediaType.startsWith('text/') ||
    TEXT_MEDIA_TYPES.has(mediaType) ||
    TEXT_FILE_EXTENSIONS.has(extensionOf(file.filename || ''))
  )
}

function decodeTextDataURL(url: string): string {
  const separator = url.indexOf(',')
  if (!url.startsWith('data:') || separator < 0) {
    throw new Error('The selected text file could not be read.')
  }

  const metadata = url.slice(5, separator)
  const payload = url.slice(separator + 1)
  try {
    if (metadata.toLowerCase().includes(';base64')) {
      const binary = atob(payload)
      const bytes = Uint8Array.from(binary, (character) =>
        character.charCodeAt(0)
      )
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
    }
    return decodeURIComponent(payload)
  } catch {
    throw new Error('The selected text file is not valid UTF-8 text.')
  }
}

function formatTextAttachment(name: string, content: string): string {
  const clipped = content.slice(0, MAX_TEXT_ATTACHMENT_CHARACTERS)
  const truncationNotice =
    content.length > MAX_TEXT_ATTACHMENT_CHARACTERS
      ? '\n[File truncated by the playground at 100,000 characters.]'
      : ''
  return `\n\n--- Attached file: ${name} ---\n${clipped}${truncationNotice}\n--- End attached file ---`
}

export function preparePlaygroundSubmission(message: {
  text?: string
  files?: FileUIPart[]
}): PlaygroundSubmission {
  let text = message.text?.trim() || ''
  const attachments: PlaygroundAttachment[] = []

  for (const file of message.files ?? []) {
    const name = normalizedFilename(file.filename)
    const mediaType =
      file.mediaType?.toLowerCase() || 'application/octet-stream'
    const url = file.url?.trim() || ''

    if (mediaType.startsWith('image/')) {
      if (!url.startsWith('data:image/')) {
        throw new Error('The selected image could not be read.')
      }
      attachments.push({ kind: 'image', name, mediaType, url })
      continue
    }

    if (!isTextAttachment(file)) {
      throw new Error(`Unsupported attachment type: ${name}`)
    }

    const content = decodeTextDataURL(url)
    if (content.includes('\u0000')) {
      throw new Error(`The selected file is not plain text: ${name}`)
    }
    text += formatTextAttachment(name, content)
    attachments.push({ kind: 'text', name, mediaType })
  }

  return { text, attachments }
}

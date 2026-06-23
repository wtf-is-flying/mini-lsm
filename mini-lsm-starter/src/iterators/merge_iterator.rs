// Copyright (c) 2022-2026 Alex Chi Z
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#![allow(unused_variables)] // TODO(you): remove this lint after implementing this mod
#![allow(dead_code)] // TODO(you): remove this lint after implementing this mod

use std::cmp::{self};
use std::collections::BinaryHeap;
use std::collections::binary_heap::PeekMut;

use anyhow::Result;

use crate::key::KeySlice;

use super::StorageIterator;

struct HeapWrapper<I: StorageIterator>(pub usize, pub Box<I>);

impl<I: StorageIterator> PartialEq for HeapWrapper<I> {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == cmp::Ordering::Equal
    }
}

impl<I: StorageIterator> Eq for HeapWrapper<I> {}

impl<I: StorageIterator> PartialOrd for HeapWrapper<I> {
    fn partial_cmp(&self, other: &Self) -> Option<cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl<I: StorageIterator> Ord for HeapWrapper<I> {
    fn cmp(&self, other: &Self) -> cmp::Ordering {
        self.1
            .key()
            .cmp(&other.1.key())
            .then(self.0.cmp(&other.0))
            .reverse() // BinaryHeap is a max-heap
    }
}

/// Merge multiple iterators of the same type. If the same key occurs multiple times in some
/// iterators, prefer the one with smaller index.
pub struct MergeIterator<I: StorageIterator> {
    /// Iterators sorted using a heap.
    /// Iterators must all be valid.
    iters: BinaryHeap<HeapWrapper<I>>,
    /// The current iterator that provides `key()` and `value()`.
    /// It must be valid if `iters` is not empty.
    current: Option<HeapWrapper<I>>,
}

impl<I: StorageIterator> MergeIterator<I> {
    pub fn create(iters: Vec<Box<I>>) -> Self {
        let mut iters: BinaryHeap<_> = iters
            .into_iter()
            .filter(|iter| iter.is_valid())
            .enumerate()
            .map(|(i, iter)| HeapWrapper(i, iter))
            .collect();

        let current = iters.pop();

        MergeIterator { iters, current }
    }
}

impl<I> StorageIterator for MergeIterator<I>
where
    I: for<'a> StorageIterator<KeyType<'a> = KeySlice<'a>> + 'static,
{
    type KeyType<'a> = KeySlice<'a>;

    fn key(&self) -> KeySlice<'_> {
        self.current
            .as_ref()
            .map(|heap_wrapper| heap_wrapper.1.key())
            .unwrap_or_else(|| KeySlice::from_slice(&[]))
    }

    fn value(&self) -> &[u8] {
        self.current
            .as_ref()
            .map(|heap_wrapper| heap_wrapper.1.value())
            .unwrap_or(&[])
    }

    fn is_valid(&self) -> bool {
        self.current
            .as_ref()
            .map(|heap_wrapper| heap_wrapper.1.is_valid())
            .unwrap_or(false)
    }

    fn next(&mut self) -> Result<()> {
        if let Some(mut current) = self.current.take() {
            // Remove all items that have the same key
            while let Some(mut next) = self.iters.peek_mut() {
                if next.1.key() == current.1.key() {
                    if let err @ Err(_) = next.1.next() {
                        PeekMut::pop(next);
                        return err;
                    }

                    if !next.1.is_valid() {
                        PeekMut::pop(next);
                    }
                } else {
                    break;
                }
            }

            // Advance the current iterator,
            // and put it back in the heap if it is still valid.
            current.1.next()?;
            if current.1.is_valid() {
                self.iters.push(current);
            }
        }

        self.current = self.iters.pop();

        Ok(())
    }
}

package app.organicmaps.sdk.util;

import androidx.annotation.NonNull;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;

/**
 * A container for observers that allows safe iteration and modification.
 * This is a replacement for org.chromium.base.ObserverList.
 *
 * @param <E> The type of observers held in this list.
 */
public class ObserverList<E> implements Iterable<E> {
    private final List<E> mObservers = new ArrayList<>();

    /**
     * Adds an observer to the list.
     *
     * @param observer The observer to add.
     * @return True if the observer was added, false if it was already in the list.
     */
    public boolean addObserver(E observer) {
        if (observer == null || mObservers.contains(observer)) {
            return false;
        }
        mObservers.add(observer);
        return true;
    }

    /**
     * Removes an observer from the list.
     *
     * @param observer The observer to remove.
     * @return True if the observer was removed, false if it was not in the list.
     */
    public boolean removeObserver(E observer) {
        return mObservers.remove(observer);
    }

    /**
     * Returns the number of observers in the list.
     */
    public int size() {
        return mObservers.size();
    }

    /**
     * Returns true if the list contains the given observer.
     */
    public boolean hasObserver(E observer) {
        return mObservers.contains(observer);
    }

    /**
     * Clears all observers from the list.
     */
    public void clear() {
        mObservers.clear();
    }

    /**
     * Returns true if the list has no observers.
     */
    public boolean isEmpty() {
        return mObservers.isEmpty();
    }

    @NonNull
    @Override
    public Iterator<E> iterator() {
        // Return a copy to allow safe iteration while the list may be modified
        return new ArrayList<>(mObservers).iterator();
    }

    /**
     * Returns a rewindable iterator that can be reset to the beginning.
     */
    public RewindableIterator<E> rewindableIterator() {
        return new RewindableIterator<>(this);
    }

    /**
     * An iterator that can be rewound to iterate from the beginning again.
     *
     * @param <E> The type of elements returned by this iterator.
     */
    public static class RewindableIterator<E> implements Iterator<E> {
        private final ObserverList<E> mList;
        private List<E> mSnapshot;
        private int mIndex;

        RewindableIterator(ObserverList<E> list) {
            mList = list;
            rewind();
        }

        /**
         * Resets the iterator to the beginning of the list.
         * Takes a new snapshot of the current observers.
         */
        public void rewind() {
            mSnapshot = new ArrayList<>(mList.mObservers);
            mIndex = 0;
        }

        @Override
        public boolean hasNext() {
            return mIndex < mSnapshot.size();
        }

        @Override
        public E next() {
            if (!hasNext()) {
                throw new NoSuchElementException();
            }
            return mSnapshot.get(mIndex++);
        }

        @Override
        public void remove() {
            throw new UnsupportedOperationException("Remove not supported");
        }
    }
}

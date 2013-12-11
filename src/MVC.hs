module MVC (
    -- * Controllers and Views
      Model
    , View(..)
    , Controller(..)

    -- * Pipe utilities
    , fromProducer
    , fromConsumer

    -- * Managed Resources
    , Managed
    , with
    , manage

    -- * Handlers
    , Handler(..)
    , handling
    , (<#>)

    -- * Re-exports
    , (<$>)
    -- $reexports
    , module Data.Functor.Constant
    , module Data.Monoid
    , module Pipes
    , module Pipes.Concurrent
    ) where

import Control.Applicative (
    Applicative(pure, (<*>)), Alternative(empty, (<|>)), (<$>), liftA2 )
import Control.Arrow (Kleisli(Kleisli, runKleisli))
import Control.Concurrent.Async (withAsync, wait)
import Control.Concurrent.STM (STM)
import Data.Functor.Constant (Constant(Constant, getConstant))
import Data.Monoid (
    Monoid(mempty, mappend, mconcat), (<>), First(First, getFirst) )
import Pipes
import Pipes.Concurrent

{-| A @(Model m a b)@ converts every @a@ into an effectful stream of 0 or more
    @b@s
-}
type Model m = Kleisli (ListT m)

-- | A `View` is an `Output` bundled with resource management logic
newtype View a = View { runView :: Managed (Output a) }

instance Monoid (View a) where
    mempty = View (pure mempty)
    mappend (View x) (View y) = View (liftA2 mappend x y)

-- | A `Controller` is an `Input` bundled with resource management logic
newtype Controller a = Controller { runController :: Managed (Input a) }

instance Functor Controller where
    fmap f (Controller x) = Controller (fmap (fmap f) x)

instance Applicative Controller where
    pure a    = Controller (pure (pure a))
    mf <*> mx = Controller $
        liftA2 (<*>) (runController mf) (runController mx)

instance Alternative Controller where
    empty = mempty
    (<|>) = mappend

instance Monoid (Controller a) where
    mempty = Controller (pure mempty)
    mappend (Controller x) (Controller y) = Controller (liftA2 mappend x y)

-- | Create a 'Controller' from a 'Producer'
fromProducer :: Producer a IO () -> Controller a
fromProducer producer = Controller $ manage $ \k -> do
    (output, input, seal) <- spawn' Unbounded
    let m = do
            runEffect $ producer >-> toOutput output
            atomically seal
    withAsync m $ \a -> do
        k input
        wait a

-- | Create a 'View' from a 'Consumer'
fromConsumer :: Consumer a IO () -> View a
fromConsumer consumer = View $ manage $ \k -> do
    (output, input, seal) <- spawn' Unbounded
    let m = do
            runEffect $ fromInput input >-> consumer
            atomically seal
    withAsync m $ \a -> do
        k output
        wait a

-- | A @(Managed r)@ is a resource @r@ bracketed by acquisition and release
newtype Managed r = Manage
    { -- | Consume a managed resource
      with :: (r -> IO ()) -> IO ()
    }

-- | Build a 'Managed' resource
manage :: ((r -> IO ()) -> IO ()) -> Managed r
manage = Manage
{-# INLINABLE manage #-}

instance Functor Managed where
    fmap f m = Manage (\k -> with m (\r -> k (f r)))

instance Applicative Managed where
    pure a    = Manage (\k -> k a)
    mf <*> mx = Manage (\k -> with mf (\f -> with mx (\x -> k (f x))))

instance Monad Managed where
    return a = Manage (\k -> k a)
    m >>= f  = Manage (\k -> with m (\a -> with (f a) k))

{-| A contravariant functor that transforms 'Maybe' Kleisli arrows to
    functions between handlers

    All instances must satisfy the following laws:

> handle return = id
> handle (f >=> g) = handle f . handle g
-}
class Handler f where
    -- | Pre-map a partial getter to define a partial handler
    handle :: (a -> Maybe b) -> f b -> f a

instance Handler Output where
    handle f o = Output $ \a ->
        case f a of
            Nothing -> return True
            Just b  -> send o b

instance Handler View where
    handle f v = View (fmap (handle f) (runView v))

{-| This is a variation on 'handle' designed to work with prisms auto-generated
    by the @lens@ library.  Think of the type as:

> handling :: (Handles f) => Prism' a b -> f b -> f a

    @(handling prism action)@ only runs the @action@ if the @prism@ matches the
    @action@'s input, using the prism to transform the input.

> handling id = id
>
> handling (p1 . p2) = handling p1 . handling p2
-}
handling
    :: (Handler f)
    => ((b -> Constant (First b) b) -> (a -> Constant (First b) a))
    -- ^
    -> (f b -> f a)
    -- ^
handling k = handle (getFirst . getConstant . k (Constant . First . Just))

-- | An infix synonym for 'handling'
(<#>)
    :: (Handler f)
    => ((b -> Constant (First b) b) -> (a -> Constant (First b) a))
    -- ^
    -> (f b -> f a)
    -- ^
(<#>) = handling

infixr 4 <#>

{- $reexports
    @Control.Arrow@ exports 'Kleisli'

    @Data.Functor.Constant@ re-exports 'Constant' (the type only)

    @Data.Monoid@ re-exports 'Monoid', ('<>'), 'mconcat', and 'First'

    @Pipes@ re-exports everything

    @Pipes.Concurrent@ re-exports everything
-}